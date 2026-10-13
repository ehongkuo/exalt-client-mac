/* Synthetic RotMGExalt for guard tests: fake IL2CPP API, scripted HP, and
 * counters for every game method the guard calls. Never touches the real game.
 *
 * Timeline (seconds):
 *   0.00-2.20  player 40 on the beach: HP 1000/1000, 400 from 1.3 (potion), 200 from 1.8 (Nexus)
 *   2.20-2.25  no player (map change)
 *   2.25-2.30  player 41's first readings: stale HP 180 and placeholder max 1100
 *   2.30-2.80  player 41 at 1000/1000
 *   2.80-      player 41 at 100/1000, in the Nexus (or on the beach with BEACH_AFTER)
 * The guard finds the HUD about 0.5 s in and then waits 0.5 s for max HP to settle.
 * Objects are small integers; class = object / 10. */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <assert.h>
#include <time.h>
typedef struct { void *pointer; } FakeMethod;
typedef struct { int length; uint16_t chars[16]; } FakeString;
static FakeMethod find_method, potion_method, nexus_method;
static unsigned finds, potion_calls, nexus_calls;
static int potion_arg = -1, class_initialized;
static char fake_exception;
static double started;
/* Like the real game: no client-side potion cooldown. With HEALING, each potion adds 100 HP once
 * the "server" reports it, 200 ms after the drink. */
static double drink_times[64];
static unsigned drinks;
#ifdef ALL_EMPTY
static int stacks[3]={0,0,0};
#else
static int stacks[3]={0,2,5};  /* first quickslot empty: potions must come from the second */
#endif
static struct { void *klass, *monitor, *bounds; uintptr_t length; void *items[3]; } quick_array={0,0,0,3,{(void*)90,(void*)91,(void*)92}};
static FakeString beach={5,{'B','e','a','c','h'}}, beach_display={7,{'{','s','.','b','e','a','c'}},
                  nexus={5,{'N','e','x','u','s'}}, nexus_display={9,{'{','s','.','n','e','x','u','s','}'}};
static double elapsed(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9-started; }
#if defined(HEALING)
static int healed(double t) { int n=0; for(unsigned i=0;i<drinks;++i) if(t-drink_times[i]>=0.2) n+=100; return n; }
/* Player 40 drops to 40% at 1.3 s and stays there except for potion heals. */
static int base_hp_at(double t) { return t<1.3?1000:t<2.2?400:t<2.3?180:1000; }
static int hp_at(double t) { int hp=base_hp_at(t)+(t<2.2?healed(t):0); return hp>1000?1000:hp; }
#elif defined(CEILING_SCRIPT)
/* Player 40 recovers in steps: 40% (drink), 70% (still under an 80% ceiling), 90% (over it). */
static int hp_at(double t) { return t<1.3?1000:t<1.6?400:t<1.9?700:t<2.2?900:t<2.3?180:1000; }
#else
static int hp_at(double t) { return t<1.3?1000:t<1.8?400:t<2.2?200:t<2.3?180:t<2.8?1000:100; }
#endif
static int max_at(double t) { return t>=2.2&&t<2.3?1100:1000; }
static int in_nexus_map(double t) {
#ifdef BEACH_AFTER
 (void)t;return 0;
#else
 return t>=2.2;
#endif
}
void *il2cpp_gchandle_new(void *o,uint8_t pinned) { (void)pinned;void **h=malloc(sizeof(void*));*h=o;return h; }
void *il2cpp_gchandle_get_target(void *h) { return *(void**)h; }
void il2cpp_gchandle_free(void *h) { free(h); }
void *il2cpp_domain_get(void) { return (void*)1; }
const void **il2cpp_domain_get_assemblies(const void *d,size_t *n) {
 (void)d; static const void *a[]={(void*)1,(void*)2};*n=2;return a;
}
const void *il2cpp_assembly_get_image(const void *a) { return a; }
const char *il2cpp_image_get_name(const void *i) { return i==(void*)1?"Assembly-CSharp.dll":"UnityEngine.CoreModule.dll"; }
static const char *class_names[]={"","Object","GuiManager","ProgressBar","FKALGHJIADI","KJMONHENJEN","EquipmentManager",
 "HJMBOMEHGDJ","LKHPPBEGNOM","QuickSlot","RealmQuestsManager","NCAFKHMPKJC","ChatManager","","CPHENFGHHNA",
 "ChatSlotController","List`1"};
void *il2cpp_class_from_name(const void *i,const char *ns,const char *name) {
 (void)i;(void)ns;
 for(uintptr_t c=1;c<sizeof class_names/sizeof *class_names;++c) if(!strcmp(name,class_names[c]))return (void*)c;
 return NULL;
}
/* Chat: ChatManager (object 120) holds the chat window's slot list (object 160, class 16) with
 * ChatSlotControllers 150-153, each showing one of the pooled message objects 140-143. Like the
 * real client, the game reuses message objects: they start empty and get new contents in place.
 *   140: party "j" from Bob, already there at start (history), then party "JJJJ!" from Eve at 1.5
 *   141: normal-chat "j cit" from Carl at 0.9, then party "Join now ->" from Frank at 1.9
 *   142: party "j cit" from Dana at 1.2
 *   143: party "j" from the user's own character at 1.7, then party "jump" from Gail at 2.0
 * Calls: Dana, Eve, Frank. The player's own name is "Me"; chat senders carry a suffix. */
typedef struct { FakeString *sender, *channel, *text; } FakeMessage;
static FakeString bob={3,{'B','o','b'}}, carl={4,{'C','a','r','l'}}, dana={4,{'D','a','n','a'}}, eve={3,{'E','v','e'}},
 frank={7,{'F','r','a','n','k',',','1'}}, gail={4,{'G','a','i','l'}}, me={7,{'M','e',',','a','b','1','2'}},
 own_name={2,{'M','e'}}, party={7,{'*','P','a','r','t','y','*'}}, none={0,{0}},
 j={1,{'j'}}, jcit={5,{'j',' ','c','i','t'}}, jjjj={5,{'J','J','J','J','!'}},
 join={10,{'J','o','i','n',' ','n','o','w',' ',0x2192}}, jump={4,{'j','u','m','p'}};
static const FakeMessage messages[]={{&none,&none,&none},{&bob,&party,&j},{&carl,&none,&jcit},{&dana,&party,&jcit},
 {&eve,&party,&jjjj},{&frank,&party,&join},{&me,&party,&j},{&gail,&party,&jump}};
static struct { void *klass, *monitor, *bounds; uintptr_t length; void *items[4]; } slot_items={0,0,0,4,{(void*)150,(void*)151,(void*)152,(void*)153}};
/* Which message each pooled object holds at time t (an index into messages). */
static int chat_content(void *o,double t) {
 switch((uintptr_t)o){
 case 140: return t<1.5?1:4;
 case 141: return t<0.9?0:t<1.9?2:5;
 case 142: return t<1.2?0:3;
 case 143: return t<1.7?0:t<2.0?6:7;
 }
 abort();
}
const void *il2cpp_class_get_type(void *c) { return c; }
void *il2cpp_type_get_object(const void *t) { return (void*)t; }
const void *il2cpp_class_get_methods(void *c,void **it) {
 if(*it)return NULL;
 FakeMethod *m=c==(void*)1?&find_method:c==(void*)6?&potion_method:c==(void*)7?&nexus_method:NULL;
 *it=m;return m;
}
const char *il2cpp_method_get_name(const void *m) {
 return m==&find_method?"FindObjectOfType":m==&potion_method?"OnQuickslotHotkeyPressedHandler":"GGGHNGEJPDE";
}
uint32_t il2cpp_method_get_param_count(const void *m) { return m==&nexus_method?0:1; }
const void *il2cpp_method_get_param(const void *m,uint32_t i) { (void)i;return m==&find_method?(void*)90:(void*)91; }
void *il2cpp_runtime_invoke(const void *m,void *o,void **p,void **e) {
 *e=NULL;
 if(m==&find_method){
  ++finds;
  if(p[0]==(void*)6)return (void*)60;
#ifdef NO_MAP
  if(p[0]==(void*)10)return NULL;
#endif
  if(p[0]==(void*)10)return (void*)100;
#ifdef NO_CHAT
  if(p[0]==(void*)12)return NULL;
#endif
  if(p[0]==(void*)12)return (void*)120;
#ifdef NO_GUI
  return NULL;
#else
  return (void*)20;
#endif
 }
 if(m==&potion_method){assert(o==(void*)60);potion_arg=*(int*)p[0];
  /* Like the game: an index outside the quickslot array throws before anything is used. */
  int i=potion_arg-1000001;
#ifdef BAD_INDEX
  i=-1;
#endif
  if(i<0||i>=3){*e=&fake_exception;return NULL;}
  assert(stacks[i]>0);
  if(drinks<64) drink_times[drinks++]=elapsed();
  ++potion_calls;--stacks[i];return NULL;}
 if(m==&nexus_method){assert(o==(void*)70);++nexus_calls;return NULL;}
 abort();
}
void *il2cpp_object_get_class(void *o) { return (void*)((uintptr_t)o/10); }
const char *il2cpp_class_get_name(void *c) { return (uintptr_t)c<sizeof class_names/sizeof *class_names?class_names[(uintptr_t)c]:"Fixture"; }
void *il2cpp_class_get_parent(void *c) { return c==(void*)4?(void*)8:c==(void*)8?(void*)5:NULL; }
static const char *field_names[]={"","hpProgressBar","JLFBFCOFDOF","OJAHBHNIGDI","DGNPJNFGFPE","","","m_CachedPtr","","",
 "OADOHPKBPJB","ABCPKBGJPEP","EFAGNJBDCOM","FirstQuickslotIndex","BBFODHPMFCC","quickSlots","JFBFHHAJOAK",
 "PNOBIMOELCK","MJGBECCHGIP","FHLCMICEGNM","GCKDOJPIMLD",
 "","","","DPGEBOCBKEF","JPDFALDPJCK","HOAKHDPFALM","","","","",
 "CPEAFDEENOD","HPGHGFMACLH","_items","_size"};
static const char *field_types[]={"","DecaGames.RotMG.UI.Helpers.ProgressBar","FKALGHJIADI","System.Single","Unity.Mathematics.float3","","","System.IntPtr","","",
 "System.Int32","System.Int32","HJMBOMEHGDJ","System.Int32","System.Single","DecaGames.RotMG.Managers.Equipment.QuickSlot[]","System.Int32",
 "NCAFKHMPKJC","System.String","System.String","System.Boolean",
 "","","","System.String","System.String","System.String",
 "","","","",
 "System.Collections.Generic.List<DecaGames.RotMG.Chat.UI.ChatSlotController>","CPHENFGHHNA",
 "DecaGames.RotMG.Chat.UI.ChatSlotController[]","System.Int32"};
void *il2cpp_class_get_field_from_name(void *c,const char *n) {
 (void)c;
 for(uintptr_t f=1;f<sizeof field_names/sizeof *field_names;++f) if(*field_names[f]&&!strcmp(n,field_names[f]))return (void*)f;
 return NULL;
}
const void *il2cpp_field_get_type(void *f) { return f; }
int il2cpp_field_get_flags(void *f) { return f==(void*)13?54:6; }
char *il2cpp_type_get_name(const void *t) {
 return strdup(t==(void*)90?"System.Type":t==(void*)91?"System.Int32":field_types[(uintptr_t)t]);
}
void il2cpp_field_get_value(void *o,void *f,void *v) {
 double t=elapsed();
 switch((uintptr_t)f){
 case 1:*(void**)v=(void*)30;return;
 case 2:*(void**)v=t>=2.2&&t<2.25?NULL:t<2.2?(void*)40:(void*)41;return;
#if defined(HUD_WRONG)
 case 3:*(float*)v=1;return;          /* never matches the player value: wrong field */
#elif defined(HUD_FROZEN)
 case 3:*(float*)v=1000;return;       /* matches once at full HP, then lags */
#else
 case 3:*(float*)v=(float)hp_at(t);return;
#endif
 case 4:{float xy[]={12,34,0};memcpy(v,xy,sizeof xy);return;}
 case 7:*(void**)v=(void*)1;return;
 case 10:*(int*)v=max_at(t);return;
 case 11:*(int*)v=hp_at(t);return;
 case 12:*(void**)v=(void*)70;return;
 case 14:*(float*)v=1000;return;
 case 15:assert(o==(void*)60);*(void**)v=&quick_array;return;
 case 16:assert((uintptr_t)o>=90&&(uintptr_t)o<=92);*(int*)v=stacks[(uintptr_t)o-90];return;
 case 17:assert(o==(void*)100);*(void**)v=in_nexus_map(t)?(void*)111:(void*)110;return;
 case 18:*(void**)v=o==(void*)111?&nexus:&beach;return;
 case 19:*(void**)v=o==(void*)111?&nexus_display:&beach_display;return;
 case 20:assert((uintptr_t)o>=90&&(uintptr_t)o<=92);*(uint8_t*)v=0;return;   /* never set in the real game */
 case 24:if(o==(void*)40||o==(void*)41){*(void**)v=&own_name;return;}   /* the character's name */
  *(void**)v=messages[chat_content(o,t)].sender;return;
 case 25:*(void**)v=messages[chat_content(o,t)].channel;return;
 case 26:*(void**)v=messages[chat_content(o,t)].text;return;
 case 31:assert(o==(void*)120);*(void**)v=(void*)160;return;
 case 32:assert((uintptr_t)o>=150&&(uintptr_t)o<=153);*(void**)v=(void*)((uintptr_t)o-10);return;
 case 33:assert(o==(void*)160);*(void**)v=&slot_items;return;
 case 34:assert(o==(void*)160);*(int*)v=4;return;
 }
 abort();
}
/* The game's static constructor sets FirstQuickslotIndex; before it runs the field reads 0. */
void il2cpp_field_static_get_value(void *f,void *v) {
 assert(f==(void*)13);*(int*)v=class_initialized?1000001:0;
}
void il2cpp_runtime_class_init(void *c) { assert(c==(void*)6);class_initialized=1; }
void il2cpp_format_exception(const void *ex,char *message,int size) {
 assert(ex==&fake_exception);snprintf(message,(size_t)size,"System.IndexOutOfRangeException: Index was outside the bounds of the array.");
}
int32_t il2cpp_string_length(void *s) { return ((FakeString*)s)->length; }
uint16_t *il2cpp_string_chars(void *s) { return ((FakeString*)s)->chars; }
void il2cpp_free(void *p) { free(p); }
uint32_t il2cpp_array_length(void *a) { assert(a==&quick_array||a==&slot_items);return (uint32_t)((uintptr_t*)a)[3]; }
static void stop(void *p) {
 (void)p;assert(finds<=20);
 printf("potion_calls=%u potion_arg=%d nexus_calls=%u\n",potion_calls,potion_arg,nexus_calls);
 exit(0);
}
int main(void) {
 started=elapsed();
 Dl_info self; assert(dladdr((void*)&il2cpp_domain_get,&self));
 char *base=self.dli_fbase;
 find_method.pointer=base+0x100;
#ifdef BAD_OFFSET
 potion_method.pointer=base+0x52cc70;
#else
 potion_method.pointer=base+0x52cc60;
#endif
 nexus_method.pointer=base+0x7264f0;
 dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),NULL,stop);
 dispatch_main();
}
