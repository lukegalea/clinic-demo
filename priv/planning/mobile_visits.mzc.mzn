% =============================================================================
% mobile_visits.mzc.mzn -- solution checker for mobile_visits.mzn. SYNTHETIC.
%
% Receives the model's data and the candidate's decision variables (st, succ, tin)
% as PARAMETERS and re-derives every hard rule in a different formulation from the
% model: the model chains nodes with a successor circuit and one element constraint
% per arc; the checker instead SORTS the tasks by start time and checks each
% consecutive pair, counts per-minute occupancy instead of reasoning about arcs, and
% ignores the candidate's `succ` and `tin` entirely (it recomputes the legs from the
% time order and the matrix). A violated rule makes the checker UNSATISFIABLE, which
% MiniZinc reports as the solution's `_checker` value; AshPlanning's Solverl backend
% records that as `checker_ok?: false`.
%
% It proves feasibility, never optimality: the weights are not repeated here.
%
% Half-open intervals throughout: [from, to), `to` exclusive. An unreachable pair
% (`reach` false) is a violation whenever a leg uses it: never a zero.
% =============================================================================

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
array[int] of int: v_prev;

int: n_commit;
set of int: COMMIT = 1..n_commit;
array[int] of int: c_from;
array[int] of int: c_to;
array[int] of int: c_loc;

int: n_block;
set of int: BLOCK = 1..n_block;
array[int] of int: b_from;
array[int] of int: b_to;

% Data the model uses for its objective only; declared so the shared data file fits,
% never read (the checker proves feasibility, not optimality).
int: w_travel;
int: w_move;
int: w_finish;

% The candidate under test: start of every node (visits, commitments, day start, day
% end). `succ` and `tin` are the model's own bookkeeping and are not trusted.
int: n_node = n_visit + n_commit + 2;
array[int] of int: st;
array[int] of int: succ;
array[int] of int: tin;

% Tasks: the visits at their candidate starts, then the pinned commitments.
int: n_task = n_visit + n_commit;
set of int: TASK = 1..n_task;
array[TASK] of int: tfrom = [st[i] | i in VISIT] ++ [c_from[j] | j in COMMIT];
array[TASK] of int: tdur = [v_dur[i] | i in VISIT] ++ [c_to[j] - c_from[j] | j in COMMIT];
array[TASK] of int: tto = [tfrom[k] + tdur[k] | k in TASK];
array[TASK] of int: tloc = [v_loc[i] | i in VISIT] ++ [c_loc[j] | j in COMMIT];

% Every visit starts inside its window and ends inside it, service included.
constraint forall(i in VISIT)(v_from[i] <= st[i] /\ st[i] + v_dur[i] <= v_to[i]);

% Capacity one: at no minute of the day is the vet in two places.
constraint forall(m in 0..horizon - 1)(
  sum(k in TASK)(bool2int(tfrom[k] <= m /\ m < tto[k])) <= 1
);

% The vet's day in time order: position 0 is the start of the day, 1..n_task the tasks
% by start, n_task + 1 the end of the day.
array[1..n_task] of int: ord = if n_task = 0 then [] else arg_sort(tfrom) endif;

function int: ploc(int: p) =
  if p = 0 then start_loc elseif p = n_task + 1 then end_loc else tloc[ord[p]] endif;
function int: pfrom(int: p) =
  if p = 0 then work_from elseif p = n_task + 1 then st[n_node] else tfrom[ord[p]] endif;
function int: pto(int: p) =
  if p = 0 then work_from elseif p = n_task + 1 then st[n_node] else tto[ord[p]] endif;
function int: leg(int: p) = tt[(ploc(p - 1) - 1) * n_loc + ploc(p)];

% Every leg uses a reachable pair and fits between the end of what came before and
% the start of what comes next: travel is explicit, never squeezed, never zero for an
% unreachable pair.
constraint forall(p in 1..n_task + 1)(
  reach[(ploc(p - 1) - 1) * n_loc + ploc(p)] /\
  pto(p - 1) + leg(p) <= pfrom(p)
);

% The vet is back inside working hours.
constraint pfrom(n_task + 1) <= work_to;

% Blocked time: no visit's service and no leg's travel interval [arrival - leg, arrival)
% overlaps it.
constraint forall(k in BLOCK, i in VISIT)(
  st[i] + v_dur[i] <= b_from[k] \/ b_to[k] <= st[i]
);
constraint forall(k in BLOCK, p in 1..n_task + 1)(
  pfrom(p) <= b_from[k] \/ b_to[k] <= pfrom(p) - leg(p)
);

output ["CORRECT\n"];
