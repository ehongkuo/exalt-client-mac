#include "../guard/guard_core.h"
#include <assert.h>
#include <stdio.h>

#define MS 1000000ULL

static void test_parse(void) {
    GuardConfig c;
    assert(guard_parse(&c, NULL));
    assert(!c.armed && c.potion == 50 && c.ceiling == 0 && c.nexus == 25);
    assert(c.min_interval_ns == 250 * MS && c.heal_timeout_ns == 1000 * MS);
    assert(guard_parse(&c, "armed=1,potion=60,nexus=20"));
    assert(c.armed && c.potion == 60 && c.nexus == 20);
    assert(guard_parse(&c, "potion=0,nexus=30"));      /* potion disabled */
    assert(c.potion == 0 && c.nexus == 30);
    assert(guard_parse(&c, "armed=1,potion=50,ceiling=80,nexus=25"));
    assert(c.ceiling == 80);
    /* Anything invalid falls back to safe defaults and is never armed. */
    const char *bad[] = {"armed=1,potion=20,nexus=30", "armed=1,nexus=101", "armed=1,slot=0",
                         "armed=1,bogus=1", "armed=1,potion=abc", "armed=2", "armed=1,nexus=-1",
                         "armed=1,potion=50,ceiling=50", "armed=1,potion=50,ceiling=40", "armed=1,potion=0,ceiling=80",
                         "armed=1,ceiling=101"};
    for (unsigned i = 0; i < sizeof bad / sizeof *bad; ++i) {
        assert(!guard_parse(&c, bad[i]));
        assert(!c.armed && c.potion == 50 && c.nexus == 25);
    }
}

/* Readings arrive this long after the first sample, past the 500 ms settle time. */
#define SETTLED (600 * MS)
#define D(state, cfg, id, hp, max, t, valid) guard_decide(state, cfg, id, hp, max, t, valid, 0, 1)

static void test_decide(void) {
    GuardConfig c; guard_parse(&c, "armed=1,potion=50,nexus=25");
    assert(c.settle_ns == 500 * MS);
    GuardState s = {0};
    assert(D(&s, &c, 1, 1000, 1000, 0, 1) == GUARD_NONE);
    /* Healthy, invalid, or nonsensical readings never act. */
    assert(D(&s, &c, 1, 100, 1000, SETTLED + 1 * MS, 0) == GUARD_NONE);
    assert(D(&s, &c, 1, 0, 1000, SETTLED + 2 * MS, 1) == GUARD_NONE);
    assert(D(&s, &c, 1, 2000, 1000, SETTLED + 4 * MS, 1) == GUARD_NONE);
    assert(D(&s, &c, 1, NAN, 1000, SETTLED + 5 * MS, 1) == GUARD_NONE);
    /* One potion, then wait for the heal to show (or 1 s) before another. */
    assert(D(&s, &c, 1, 500, 1000, SETTLED + 10 * MS, 1) == GUARD_POTION);
    assert(D(&s, &c, 1, 400, 1000, SETTLED + 300 * MS, 1) == GUARD_NONE);
    assert(D(&s, &c, 1, 400, 1000, SETTLED + 1010 * MS, 1) == GUARD_POTION);
    /* Nexus wins below its threshold, fires once, then everything stops. */
    assert(D(&s, &c, 1, 250, 1000, SETTLED + 1020 * MS, 1) == GUARD_NEXUS);
    assert(D(&s, &c, 1, 100, 1000, SETTLED + 5000 * MS, 1) == GUARD_NONE);
    assert(D(&s, &c, 1, 400, 1000, SETTLED + 9000 * MS, 1) == GUARD_NONE);
    /* A new player object (new map or character) re-arms after it settles. */
    assert(D(&s, &c, 2, 100, 1000, 20000 * MS, 1) == GUARD_NONE);
    assert(D(&s, &c, 2, 100, 1000, 20000 * MS + SETTLED, 1) == GUARD_NEXUS);
    /* Straight to Nexus when the first low reading is already below both thresholds. */
    GuardState t = {0};
    assert(D(&t, &c, 3, 1000, 1000, 0, 1) == GUARD_NONE);
    assert(D(&t, &c, 3, 50, 1000, SETTLED, 1) == GUARD_NEXUS);
    /* Disabled potion threshold: only Nexus. */
    GuardConfig n; guard_parse(&n, "potion=0,nexus=25");
    GuardState u = {0};
    assert(D(&u, &n, 4, 1000, 1000, 0, 1) == GUARD_NONE);
    assert(D(&u, &n, 4, 300, 1000, SETTLED, 1) == GUARD_NONE);
    assert(D(&u, &n, 4, 200, 1000, SETTLED + 1 * MS, 1) == GUARD_NEXUS);
}

static void test_settle(void) {
    GuardConfig c; guard_parse(&c, "armed=1,potion=50,nexus=25");
    GuardState s = {0};
    /* The live bug: a new player object's first reading had stale HP and a placeholder max. */
    assert(D(&s, &c, 7, 18, 110, 0, 1) == GUARD_NONE);
    assert(D(&s, &c, 7, 85, 85, 70 * MS, 1) == GUARD_NONE);
    /* Max HP changed at 70 ms, so nothing happens until 570 ms. */
    assert(D(&s, &c, 7, 18, 85, 560 * MS, 1) == GUARD_NONE);
    assert(D(&s, &c, 7, 18, 85, 570 * MS, 1) == GUARD_NEXUS);
    /* An equipment swap that changes max HP restarts the wait. */
    GuardState e = {0};
    assert(D(&e, &c, 8, 1000, 1000, 0, 1) == GUARD_NONE);
    assert(D(&e, &c, 8, 400, 1100, SETTLED, 1) == GUARD_NONE);
    assert(D(&e, &c, 8, 400, 1100, SETTLED + 499 * MS, 1) == GUARD_NONE);
    assert(D(&e, &c, 8, 400, 1100, SETTLED + 500 * MS, 1) == GUARD_POTION);
    /* Invalid readings neither act nor restart the wait. */
    GuardState v = {0};
    assert(D(&v, &c, 9, 1000, 1000, 0, 1) == GUARD_NONE);
    assert(D(&v, &c, 9, 0, 0, 100 * MS, 0) == GUARD_NONE);
    assert(D(&v, &c, 9, 200, 1000, 500 * MS, 1) == GUARD_NEXUS);
}

static void test_in_nexus(void) {
    GuardConfig c; guard_parse(&c, "armed=1,potion=50,nexus=25");
    GuardState s = {0};
    assert(guard_decide(&s, &c, 1, 1000, 1000, 0, 1, 1, 1) == GUARD_NONE);
    assert(guard_decide(&s, &c, 1, 400, 1000, SETTLED, 1, 1, 1) == GUARD_NONE);
    assert(guard_decide(&s, &c, 1, 100, 1000, SETTLED + 1 * MS, 1, 1, 1) == GUARD_NONE);
    /* Leaving the Nexus (same player object, map known to be elsewhere) acts again. */
    assert(guard_decide(&s, &c, 1, 100, 1000, SETTLED + 2 * MS, 1, 0, 1) == GUARD_NEXUS);
}

#define P(state, cfg, hp, t, ready) guard_decide(state, cfg, 5, hp, 1000, t, 1, 0, ready)
static void test_ceiling_and_pacing(void) {
    GuardConfig c; guard_parse(&c, "armed=1,potion=50,ceiling=80,nexus=25");
    GuardState s = {0};
    assert(P(&s, &c, 1000, 0, 1) == GUARD_NONE);
    assert(P(&s, &c, 600, SETTLED, 1) == GUARD_NONE);                 /* above the trigger */
    assert(P(&s, &c, 500, SETTLED + 1 * MS, 1) == GUARD_POTION);      /* trigger crossed */
    assert(s.drinking);
    /* The live bug: HP updates arrive about every 200 ms, so until the heal shows the guard
     * keeps seeing the old HP. It must not drink again on that stale reading. */
    for (int t = 50; t <= 900; t += 50) assert(P(&s, &c, 500, SETTLED + (uint64_t)t * MS, 1) == GUARD_NONE);
    /* Heal shown (HP above the drink-time HP) but under 250 ms since the drink: still wait. */
    GuardState h = {0};
    assert(P(&h, &c, 1000, 0, 1) == GUARD_NONE);
    assert(P(&h, &c, 500, SETTLED, 1) == GUARD_POTION);
    assert(P(&h, &c, 600, SETTLED + 200 * MS, 1) == GUARD_NONE);
    /* Heal shown and 250 ms passed: next potion. Keeps going up to the ceiling. */
    assert(P(&h, &c, 600, SETTLED + 260 * MS, 1) == GUARD_POTION);
    assert(P(&h, &c, 700, SETTLED + 520 * MS, 1) == GUARD_POTION);
    assert(P(&h, &c, 800, SETTLED + 780 * MS, 1) == GUARD_POTION);    /* at the ceiling: not over it */
    assert(P(&h, &c, 810, SETTLED + 1040 * MS, 1) == GUARD_NONE);     /* over the ceiling: stop */
    assert(!h.drinking);
    assert(P(&h, &c, 700, SETTLED + 1300 * MS, 1) == GUARD_NONE);     /* above trigger again: no restart */
    /* A new crossing starts a new run straight away (250 ms floor permitting). */
    assert(P(&h, &c, 490, SETTLED + 1600 * MS, 1) == GUARD_POTION);
    /* Hit again after drinking: HP fell instead of rising, so wait out the 1 s heal window. */
    assert(P(&h, &c, 300, SETTLED + 1700 * MS, 1) == GUARD_NONE);
    assert(P(&h, &c, 300, SETTLED + 2599 * MS, 1) == GUARD_NONE);
    assert(P(&h, &c, 300, SETTLED + 2601 * MS, 1) == GUARD_POTION);
    /* Without a ceiling, drinking stops as soon as HP is back above the trigger. */
    GuardConfig n; guard_parse(&n, "armed=1,potion=50,nexus=25");
    GuardState t = {0};
    assert(P(&t, &n, 1000, 0, 1) == GUARD_NONE);
    assert(P(&t, &n, 400, SETTLED, 1) == GUARD_POTION);
    assert(P(&t, &n, 600, SETTLED + 300 * MS, 1) == GUARD_NONE);
    /* Not ready (no potions): never drinks; Nexus still works. */
    GuardState u = {0};
    assert(P(&u, &c, 1000, 0, 0) == GUARD_NONE);
    assert(P(&u, &c, 400, SETTLED, 0) == GUARD_NONE);
    assert(P(&u, &c, 200, SETTLED + 1 * MS, 0) == GUARD_NEXUS);
    /* Leaving drinking mode in the Nexus. */
    GuardState v = {0};
    assert(P(&v, &c, 1000, 0, 1) == GUARD_NONE);
    assert(P(&v, &c, 400, SETTLED, 1) == GUARD_POTION);
    assert(guard_decide(&v, &c, 5, 400, 1000, SETTLED + 100 * MS, 1, 1, 1) == GUARD_NONE);
    assert(!v.drinking);
}

static void test_pick_slot(void) {
    int counts[] = {3, 5, 2};
    assert(guard_pick_slot(counts, 3) == 0);           /* first until it runs out */
    counts[0] = 0;
    assert(guard_pick_slot(counts, 3) == 1);           /* then second */
    counts[1] = 0;
    assert(guard_pick_slot(counts, 3) == 2);           /* then third */
    counts[2] = 0;
    assert(guard_pick_slot(counts, 3) == -1);          /* all empty */
    int two[] = {0, 4};
    assert(guard_pick_slot(two, 2) == 1);              /* characters with two slots */
    int odd[] = {-1, 1};
    assert(guard_pick_slot(odd, 2) == 1);              /* negative counts are empty */
    assert(guard_pick_slot(counts, 0) == -1);
}

static void test_apply(void) {
    GuardConfig c; guard_parse(&c, "armed=1,potion=50,ceiling=80,nexus=25");
    GuardState s = {.drinking = 1};
    /* A valid change replaces the four settings and keeps the internal ones. */
    assert(guard_apply(&c, &s, 0, 40, 70, 15));
    assert(!c.armed && c.potion == 40 && c.ceiling == 70 && c.nexus == 15);
    assert(c.min_interval_ns == 250 * MS && c.heal_timeout_ns == 1000 * MS && c.settle_ns == 500 * MS);
    /* Changing thresholds ends a drinking run; the next crossing starts a new one. */
    assert(!s.drinking);
    /* Invalid changes are refused and leave everything as it was. */
    int bad[][4] = {{1, 50, 0, 50}, {1, 50, 40, 25}, {1, 101, 0, 25}, {2, 50, 0, 25},
                    {1, 0, 80, 25}, {1, 50, 0, -1}, {-1, 50, 0, 25}, {1, 50, 101, 25}};
    for (unsigned i = 0; i < sizeof bad / sizeof *bad; ++i) {
        s.drinking = 1;
        assert(!guard_apply(&c, &s, bad[i][0], bad[i][1], bad[i][2], bad[i][3]));
        assert(!c.armed && c.potion == 40 && c.ceiling == 70 && c.nexus == 15 && s.drinking);
    }
    /* Disabling either threshold is allowed. */
    assert(guard_apply(&c, &s, 1, 0, 0, 30));
    assert(guard_apply(&c, &s, 1, 60, 0, 0));
}

static void test_chat_call(void) {
    const char *calls[] = {"j", "J", "jjjjj", "JJjj", "j cit", "j inf", "JJ O3 now", "j!", "jjj...", "  j",
                           "join", "Join now", "JOIN!", "j?"};
    for (unsigned i = 0; i < sizeof calls / sizeof *calls; ++i) assert(chat_is_call(calls[i]));
    const char *not_calls[] = {"", " ", "!", "jump", "jk", "joined", "rejoin", "hello j", "can i join",
                               "j1", "jo", "s?", NULL};
    for (unsigned i = 0; i < sizeof not_calls / sizeof *not_calls; ++i) assert(!chat_is_call(not_calls[i]));
    assert(chat_same_name("Wehatelife,a19d,c84c", "wehatelife"));
    assert(chat_same_name("Me", "Me,ab12"));
    assert(!chat_same_name("Teratopositor,cbf9", "Wehatelife"));
    assert(!chat_same_name("Me", "Mel"));
    assert(!chat_same_name("", ""));
    assert(!chat_same_name(",x", ",x"));
}

int main(void) {
    test_chat_call();
    test_apply();
    test_pick_slot();
    test_parse();
    test_decide();
    test_settle();
    test_in_nexus();
    test_ceiling_and_pacing();
    puts("Guard decision tests passed");
}
