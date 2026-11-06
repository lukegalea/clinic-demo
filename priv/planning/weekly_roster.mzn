% =============================================================================
% weekly_roster.mzn -- the clinic's weekly staffing roster. SYNTHETIC and public.
%
% Decides two things over one Monday-to-Sunday week on a fixed slot grid:
%   * pat[c, d]  which shift pattern (template) clinician c works on day d
%                (0 = does not work that day);
%   * asg[a]     which clinician covers appointment a (0 = left UNCOVERED).
%
% The solver never moves an appointment: a_from/a_to are inputs, fixed by the
% booking. It only chooses who works when, and who attends what. Every rule it
% needs (role, allowed days, availability, reserve) arrives as DATA; nothing
% about a particular clinic is written into this file.
%
% Data arrays that can be empty (no appointments, no removed availability...) arrive
% with ONE trailing pad element: Solverl renders an empty list as `array0d([])`,
% which MiniZinc rejects for a one-dimensional array. They are declared
% `array[int]` and the model reads only the first `n_*` entries, so the pad is
% never seen.
%
% Slots are `slot_minutes` long; a slot index is absolute within the week
% (0 .. 7*spd - 1) and all intervals are half-open [from, to). An appointment
% occupies the slots from floor(start) up to ceil(end), so a rounded appointment
% never frees a slot it uses.
%
% Objective v1 (minimise): weighted uncovered appointments
%                          + idle slots inside worked shifts (fragmentation proxy:
%                            paid time that covers nothing)
%                          + disturbance of the previously applied plan
%                            (shift changed / appointment reassigned)
%                          + continuity loss (covered by someone other than the
%                            booked clinician).
% The weights are data too (`w_*`), so a review changes them without a model edit.
% =============================================================================

int: spd;                         % slots per day
int: n_days = 7;

% --- clinicians (index 1..n_clin) and their roles (1 vet, 2 technician, 3 nurse)
int: n_clin;
set of int: CLIN = 1..n_clin;
array[int] of int: clin_role;

% --- shift templates: a role, a [from, to) slot window inside a day, and which
%     days of the week (1 = Monday) the policy allows the pattern to start on.
int: n_tmpl;
set of int: TMPL = 1..n_tmpl;
array[int] of int: t_role;
array[int] of int: t_from;
array[int] of int: t_to;
array[int] of bool: t_day_ok;     % ((p - 1) * 7 + d)

% --- availability removed: clinician c cannot work in the absolute [u_from, u_to)
int: n_unavail;
set of int: UNAVAIL = 1..n_unavail;
array[int] of int: u_clin;
array[int] of int: u_from;
array[int] of int: u_to;

% --- appointments, fixed in time.
int: n_appt;
set of int: APPT = 1..n_appt;
array[int] of int: a_from;
array[int] of int: a_to;
array[int] of int: a_role;       % required role (policy: qualification)
array[int] of int: a_weight;     % cost of leaving it uncovered
array[int] of int: a_booked;     % the booked clinician (0 = none): continuity
array[int] of int: a_prev;       % previously applied covering clinician (0 = none)

% --- the previously applied roster: -1 = no previous plan for that clinician-day
array[int] of int: prev_pat;      % ((c - 1) * 7 + d)

array[1..n_days] of int: reserve_slots;   % per weekday: kept unassigned in every worked clinician-day

int: w_uncovered;
int: w_idle;
int: w_shift_change;
int: w_assign_change;
int: w_continuity;

% Appointments stay inside one day.
constraint assert(forall(a in APPT)((a_to[a] - 1) div spd = a_from[a] div spd),
  "an appointment must not cross midnight");

function int: day_of(int: a) = a_from[a] div spd + 1;

% Index 0 stands for "nobody"; row 0 of the pattern array is a dummy that never works.
array[0..n_tmpl] of int: tfrom0 = array1d(0..n_tmpl, [0] ++ [t_from[p] | p in TMPL]);
array[0..n_tmpl] of int: tto0 = array1d(0..n_tmpl, [0] ++ [t_to[p] | p in TMPL]);

array[1..(n_clin + 1) * n_days] of var 0..n_tmpl: pat;   % (c * 7 + d), c in 0..n_clin
array[APPT] of var 0..n_clin: asg;

% Clinician 0 never works.
constraint forall(d in 1..n_days)(pat[d] = 0);

% A pattern must fit the clinician's role and an allowed day. Both are known from
% the data, so they are stated as domains: propagation prunes them before search.
constraint forall(c in CLIN, d in 1..n_days)(
  pat[c * n_days + d] in {0} union
    {p | p in TMPL where t_role[p] = clin_role[c] /\ t_day_ok[(p - 1) * n_days + d]}
);

function var int: sf(var int: c, int: d) = (d - 1) * spd + tfrom0[pat[c * n_days + d]];
function var int: st(var int: c, int: d) = (d - 1) * spd + tto0[pat[c * n_days + d]];

% A worked shift never overlaps availability that was removed.
constraint forall(k in UNAVAIL, d in 1..n_days)(
  pat[u_clin[k] * n_days + d] != 0 ->
    (st(u_clin[k], d) <= u_from[k] \/ u_to[k] <= sf(u_clin[k], d))
);

% A covered appointment is attended by a clinician of the required role (a domain:
% the role is data) who works a shift that contains it entirely.
constraint forall(a in APPT)(
  asg[a] in {0} union {c | c in CLIN where clin_role[c] = a_role[a]}
);

constraint forall(a in APPT)(
  asg[a] != 0 ->
    (pat[asg[a] * n_days + day_of(a)] != 0 /\
     sf(asg[a], day_of(a)) <= a_from[a] /\
     a_to[a] <= st(asg[a], day_of(a)))
);

% One clinician cannot attend two overlapping appointments (half-open overlap).
constraint forall(a in APPT, b in APPT where a < b /\ a_from[a] < a_to[b] /\ a_from[b] < a_to[a])(
  asg[a] = 0 \/ asg[b] = 0 \/ asg[a] != asg[b]
);

% Reserve capacity: a worked clinician-day keeps `reserve_slots` unassigned.
function var int: busy(int: c, int: d) =
  sum(a in APPT where day_of(a) = d)((a_to[a] - a_from[a]) * bool2int(asg[a] = c));

constraint forall(c in CLIN, d in 1..n_days)(
  pat[c * n_days + d] != 0 ->
    busy(c, d) <= st(c, d) - sf(c, d) - reserve_slots[d]
);

% Dominance (sound, only prunes): a worked shift that covers nothing is never better
% than not working it, unless it is the previously applied pattern (keeping that costs
% nothing in `shift_changes`, removing it costs `w_shift_change`).
constraint forall(c in CLIN, d in 1..n_days)(
  pat[c * n_days + d] != 0 ->
    (busy(c, d) > 0 \/ pat[c * n_days + d] = prev_pat[(c - 1) * n_days + d])
);

var int: uncovered = sum(a in APPT)(a_weight[a] * bool2int(asg[a] = 0));
var int: idle = sum(c in CLIN, d in 1..n_days)(
  bool2int(pat[c * n_days + d] != 0) * (st(c, d) - sf(c, d) - busy(c, d)));
var int: shift_changes = sum(c in CLIN, d in 1..n_days)(
  bool2int(prev_pat[(c - 1) * n_days + d] >= 0 /\ pat[c * n_days + d] != prev_pat[(c - 1) * n_days + d]));
var int: assign_changes = sum(a in APPT where a_prev[a] != 0)(bool2int(asg[a] != a_prev[a]));
var int: continuity_loss = sum(a in APPT where a_booked[a] != 0)(
  bool2int(asg[a] != 0 /\ asg[a] != a_booked[a]));

var int: obj = w_uncovered * uncovered + w_idle * idle + w_shift_change * shift_changes
             + w_assign_change * assign_changes + w_continuity * continuity_loss;

% Cover first (largest clinician index first), then leave every unused clinician-day
% off (pattern 0): the optimum improves from a covered plan, not from an empty one.
solve :: seq_search([
  int_search(asg, first_fail, indomain_max),
  int_search(pat, input_order, indomain_min)
]) minimize obj;

output [
  "pat = ", show(pat), ";\n",
  "asg = ", show(asg), ";\n",
  "obj = ", show(obj), ";\n"
];
