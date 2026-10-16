#!/usr/bin/env python3
"""Diagnostic hypotheses only. No observed HP change is a verified hit acknowledgement."""

class ShadowLedger:
    def __init__(self,threshold=25):
        if not 0<=threshold<=100:raise ValueError('Threshold must be 0-100')
        self.threshold=threshold
        self.generation=None
        self._reset()

    def _reset(self):
        self.hp=None;self.maximum=None
        self.damage_total=0;self.held_damage=0;self.debit_pending=0
        self.observed_increases=0;self.observed_debits=0;self.unexplained_debit=0
        self.hit_count=0;self.invalid_damage=0;self.terminal=False

    def feed(self,event):
        generation=event['generation']
        if generation!=self.generation:self.generation=generation;self._reset()
        hp,maximum=event['hp'],event['max']
        if maximum<=0 or hp>maximum or (not event['valid'] and hp>0):return None
        if hp<=0 or event['phase']==13:self.terminal=True
        changed=self.hp!=hp or self.maximum!=maximum
        previous_hp=self.hp
        if previous_hp is not None:
            delta=hp-previous_hp
            if delta>0:self.observed_increases+=delta
            elif delta<0:
                debit=-delta;self.observed_debits+=debit
                credit=min(debit,self.debit_pending)
                self.debit_pending-=credit;self.unexplained_debit+=debit-credit
        self.hp=hp;self.maximum=maximum
        before_held=hp-self.held_damage;before_debit=hp-self.debit_pending
        damage=event['value'] if event['phase']==12 else 0
        if event['phase']==12 and event.get('flag1') and not event.get('flag0'):damage=0
        if event['phase']==12 and not 0<=damage<=2147483647:self.invalid_damage+=1;damage=0
        if damage>0:
            self.damage_total+=damage;self.held_damage+=damage;self.debit_pending+=damage;self.hit_count+=1
        held=hp-self.held_damage;debit=hp-self.debit_pending
        boundary=maximum*self.threshold/100
        held_crossed=damage>0 and self.threshold>0 and before_held>boundary>=held
        debit_crossed=damage>0 and self.threshold>0 and before_debit>boundary>=debit
        status='terminal' if self.terminal else 'inactive_nexus' if event['in_nexus'] else 'ambiguous' if self.held_damage else 'baseline_only'
        if not changed and not damage and event['phase'] not in (13,14,16,17,18,19):return None
        return dict(event_id=event['id'],ns=event['ns'],generation=generation,phase=event['phase'],observed_hp=hp,max_hp=maximum,
            threshold_percent=self.threshold,held_damage=self.held_damage,debit_pending=self.debit_pending,
            held_estimate=held if status not in ('terminal','inactive_nexus') else None,
            debit_estimate=debit if status not in ('terminal','inactive_nexus') else None,
            held_crossed=held_crossed if status not in ('terminal','inactive_nexus') else False,
            debit_crossed=debit_crossed if status not in ('terminal','inactive_nexus') else False,
            observed_increases=self.observed_increases,observed_debits=self.observed_debits,
            unexplained_debit=self.unexplained_debit,invalid_damage=self.invalid_damage,hit_count=self.hit_count,
            update_context=event.get('update_context',0),update_source=event.get('update_source',0),
            tick_sequence=event.get('tick_sequence',0),server_time=event.get('server_time',0),
            acknowledged=False,status=status)


def replay(events,threshold=None):
    ledger=ShadowLedger(25 if threshold is None else threshold)
    trace=[]
    for event in events:
        recorded=event.get('threshold_percent')
        if threshold is None and recorded is not None and 0<=recorded<=100:ledger.threshold=recorded
        row=ledger.feed(event)
        if row is not None:trace.append(row)
    return dict(threshold_percent=threshold,trace=trace,
        limitation='Both estimates are diagnostic hypotheses. Held damage may double-count applied damage; net-debit credit may retire the wrong damage. Incoming sequence fields do not identify acknowledged hit reports. This ledger runs in the monitor or analyzer, not in the game call, and its source timestamps are not action-decision times.')
