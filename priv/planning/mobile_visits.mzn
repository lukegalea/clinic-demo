% =============================================================================
% mobile_visits.mzn -- one veterinarian's mobile-visit route for one day.
% SYNTHETIC and public.
%
% Decides, for the day's mobile visits, WHEN each starts and in WHAT ORDER the vet
% drives them, around everything the vet's calendar already holds:
%   * pinned commitments (in-clinic or already-booked appointments): fixed in time
%     and place, the solver never moves them;
%   * blocked time (removed availability, telehealth): no service and no travel
%     may overlap it.
% The vet starts the day at `start_loc` and ends it at `end_loc`.
%
% Time is whole minutes from 00:00 UTC (0 .. horizon), intervals half-open [from, to).
% Locations are indexed 1..n_loc; the travel matrix is flattened row-major
% ((a - 1) * n_loc + b) with minutes in `tt` and reachability in `reach`.
%
% An UNREACHABLE pair (`reach` false) can never be driven: it is excluded from the
% route, never priced at zero (its `tt` entry is also `horizon`, so even a model
% edit that dropped the `reach` test could not make it cheap).
%
% Every requested visit must be placed inside its window [v_from, v_to), service
% included, with the travel into it explicit: the leg arrives exactly when the
% service starts (`tin`), so the vet's travel interval is [st - tin, st). A visit
% that fits its window but not the travel around a commitment makes the model
% UNSATISFIABLE: the plan is refused, never squeezed.
%
% Arrays that can be empty arrive with ONE trailing pad element (Solverl renders an
% empty list as `array0d([])`); they are declared `array[int]` and read only up to
% their `n_*` count.
%
% Objective (minimise): driving minutes (w_travel) + visits moved off their
% previously applied start (w_move) + the minute the vet is back (w_finish).
% =============================================================================

include "globals.mzn";

int: horizon;
int: work_from;
int: work_to;

int: n_loc;
array[int] of int: tt;
array[int] of bool: reach;
int: start_loc;
int: end_loc;

int: n_visit;
set of int: VISIT = 1..n_visit;
array[int] of int: v_from;
array[int] of int: v_to;
array[int] of int: v_dur;
array[int] of int: v_loc;
array[int] of int: v_prev;      % previously applied start, -1 = none

int: n_commit;
set of int: COMMIT = 1..n_commit;
array[int] of int: c_from;
array[int] of int: c_to;
array[int] of int: c_loc;

int: n_block;
set of int: BLOCK = 1..n_block;
array[int] of int: b_from;
array[int] of int: b_to;

int: w_travel;
int: w_move;
int: w_finish;

% Nodes: visits, then commitments, then the start (S) and end (E) of the day.
int: n_node = n_visit + n_commit + 2;
int: S = n_visit + n_commit + 1;
int: E = n_visit + n_commit + 2;
set of int: NODE = 1..n_node;

array[NODE] of int: nloc = [v_loc[i] | i in VISIT] ++ [c_loc[j] | j in COMMIT] ++ [start_loc, end_loc];
array[NODE] of int: ndur = [v_dur[i] | i in VISIT] ++ [c_to[j] - c_from[j] | j in COMMIT] ++ [0, 0];

% A visit whose window cannot hold its service time has an empty domain below: the
% model is unsatisfiable for it, not erroneous.

% st[n]: when node n starts. Visits move inside their window; commitments and the
% start of the day are fixed; the vet is back (E) no later than the end of the day.
array[NODE] of var int: st;
constraint forall(i in VISIT)(st[i] in v_from[i]..v_to[i] - v_dur[i]);
constraint forall(j in COMMIT)(st[n_visit + j] = c_from[j]);
constraint st[S] = work_from;
constraint st[E] in work_from..work_to;

% succ[n]: the node the vet goes to after n. One circuit through every node, closed
% by E -> S, so S -> ... -> E visits everything exactly once.
array[NODE] of var NODE: succ;
constraint circuit(succ);
constraint succ[E] = S;

% tin[n]: minutes of travel into n (explicit travel interval [st[n] - tin[n], st[n])).
array[NODE] of var 0..horizon: tin;
constraint tin[S] = 0;

constraint forall(n in NODE where n != E)(
  reach[(nloc[n] - 1) * n_loc + nloc[succ[n]]] /\
  tin[succ[n]] = tt[(nloc[n] - 1) * n_loc + nloc[succ[n]]] /\
  st[succ[n]] >= st[n] + ndur[n] + tin[succ[n]]
);

% Blocked time: no service and no travel overlaps it (half-open).
constraint forall(k in BLOCK, i in VISIT)(
  st[i] + v_dur[i] <= b_from[k] \/ b_to[k] <= st[i]
);
constraint forall(k in BLOCK, n in NODE where n != S)(
  st[n] <= b_from[k] \/ b_to[k] <= st[n] - tin[n]
);

var int: travel = sum(n in NODE)(tin[n]);
var int: moved = sum(i in VISIT where v_prev[i] >= 0)(bool2int(st[i] != v_prev[i]));
var int: obj = w_travel * travel + w_move * moved + w_finish * st[E];

solve :: seq_search([
  int_search(succ, first_fail, indomain_min),
  int_search(st, smallest, indomain_min)
]) minimize obj;
