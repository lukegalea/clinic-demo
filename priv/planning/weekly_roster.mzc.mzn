% =============================================================================
% weekly_roster.mzc.mzn -- solution checker for weekly_roster.mzn. SYNTHETIC.
%
% Receives the model's data and the candidate's decision variables (pat, asg) as
% PARAMETERS and re-derives every hard rule in a different formulation from the
% model: a per-slot occupancy COUNT per clinician instead of pairwise disjunctions,
% and a per-slot "is this clinician working now" predicate instead of interval
% containment arithmetic. A violated rule makes the checker UNSATISFIABLE, which
% MiniZinc reports as the solution's `_checker` value; AshPlanning's Solverl
% backend records that as `checker_ok?: false`.
%
% It proves feasibility, never optimality: the weights are not repeated here, and
% a satisfied checker is not an optimality certificate.
%
% Half-open intervals throughout: [from, to), `to` exclusive.
% =============================================================================

int: spd;
int: n_days = 7;
int: horizon = n_days * spd;

int: n_clin;
set of int: CLIN = 1..n_clin;
array[int] of int: clin_role;

int: n_tmpl;
set of int: TMPL = 1..n_tmpl;
array[int] of int: t_role;
array[int] of int: t_from;
array[int] of int: t_to;
array[int] of bool: t_day_ok;

int: n_unavail;
set of int: UNAVAIL = 1..n_unavail;
array[int] of int: u_clin;
array[int] of int: u_from;
array[int] of int: u_to;

int: n_appt;
set of int: APPT = 1..n_appt;
array[int] of int: a_from;
array[int] of int: a_to;
array[int] of int: a_role;

% Data the model uses for its objective only; declared so the shared data file
% fits, never read (the checker proves feasibility, not optimality).
array[int] of int: a_weight;
array[int] of int: a_booked;
array[int] of int: a_prev;
array[int] of int: prev_pat;
int: w_uncovered;
int: w_idle;
int: w_shift_change;
int: w_assign_change;
int: w_continuity;

array[1..n_days] of int: reserve_slots;

% The candidate under test.
array[1..(n_clin + 1) * n_days] of int: pat;
array[int] of int: asg;

% Every decision is in its domain.
constraint forall(i in index_set(pat))(0 <= pat[i] /\ pat[i] <= n_tmpl);
constraint forall(a in APPT)(0 <= asg[a] /\ asg[a] <= n_clin);

% Is clinician c on shift in absolute slot s?
function bool: working(int: c, int: s) =
  let { int: d = s div spd + 1; int: p = pat[c * n_days + d] } in
  p != 0 /\ t_from[p] <= s mod spd /\ s mod spd < t_to[p];

% Patterns fit role and allowed day.
constraint forall(c in CLIN, d in 1..n_days where pat[c * n_days + d] != 0)(
  t_role[pat[c * n_days + d]] = clin_role[c] /\ t_day_ok[(pat[c * n_days + d] - 1) * n_days + d]
);

% Nobody works through removed availability, slot by slot.
constraint forall(k in UNAVAIL, s in u_from[k]..u_to[k] - 1 where s >= 0 /\ s < horizon)(
  not working(u_clin[k], s)
);

% Covered appointments: required role, and on shift for every slot they use.
constraint forall(a in APPT where asg[a] != 0)(
  clin_role[asg[a]] = a_role[a] /\
  forall(s in a_from[a]..a_to[a] - 1)(working(asg[a], s))
);

% Capacity one per clinician per slot.
constraint forall(c in CLIN, s in 0..horizon - 1)(
  sum(a in APPT)(bool2int(asg[a] = c /\ a_from[a] <= s /\ s < a_to[a])) <= 1
);

% Reserve capacity, counted per slot per worked clinician-day.
constraint forall(c in CLIN, d in 1..n_days where pat[c * n_days + d] != 0)(
  sum(s in (d - 1) * spd..d * spd - 1)(
    bool2int(working(c, s)) - sum(a in APPT)(bool2int(asg[a] = c /\ a_from[a] <= s /\ s < a_to[a]))
  ) >= reserve_slots[d]
);

output ["CORRECT\n"];
