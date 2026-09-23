defmodule ClinicDemo.Scheduling.Appointment do
  @moduledoc """
  A booked slot: one patient, one clinician, one point in time.

  The lifecycle is a formal state machine (`AshStateMachine`): the states a
  visit may occupy and the moves between them are declared once, below, and
  every lifecycle action both drives and is checked by that declaration.
  There is no generic `:update` action — each transition is its own named
  action with its own arguments and its own guards, which is what makes the
  action contract worth reading. The BPMN visit process orchestrates *when*
  these actions run; it is never a second authority on *whether* a status
  change is allowed.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  alias ClinicDemo.Scheduling.Changes.ComplianceGuard
  alias ClinicDemo.Scheduling.Changes.StartVisitProcess
  alias ClinicDemo.Scheduling.Validations.CurrentStatusIn
  alias ClinicDemo.Scheduling.Validations.ExactlyOneOf
  alias ClinicDemo.Scheduling.Validations.NotInThePast

  postgres do
    table "appointments"
    repo ClinicDemo.Repo

    references do
      reference :patient, on_delete: :delete
      reference :clinician, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :scheduled_at, :utc_datetime do
      description "Start of the slot, always stored in UTC."
      allow_nil? false
      public? true
    end

    attribute :duration_minutes, :integer do
      description "Slot length. The clinic works in five-minute increments."
      allow_nil? false
      public? true
      default 30
      constraints min: 5, max: 240
    end

    attribute :reason, :string do
      description "Why the animal is coming in, in the owner's words."
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 200, trim?: true
    end

    attribute :status, :atom do
      description "Set only by the lifecycle actions below, never accepted as input."
      allow_nil? false
      public? true
      default :scheduled
      constraints one_of: [:scheduled, :checked_in, :completed, :cancelled, :no_show]
    end

    attribute :severity, :integer do
      description """
      How bad the presenting sign sounded when the owner rang, 1 (a nail trim)
      to 5 (collapse). One of the three inputs to the triage decision.
      """

      allow_nil? false
      public? true
      default 2
      constraints min: 1, max: 5
    end

    attribute :triage_urgency, :atom do
      description """
      What the `appointment.triage` decision answered. Nil until the visit
      process has asked, and never accepted as input — the rule decides this,
      not the caller.
      """

      public? true
      constraints one_of: [:emergency, :urgent, :soon, :routine]
    end

    attribute :notes, :string do
      description "Clinical notes, written at completion."
      public? true
      constraints max_length: 4000
    end

    attribute :discharged_at, :utc_datetime do
      description "When the animal went home. Set by :discharge, after the visit is written up."
      public? true
    end

    attribute :cancellation_reason, :string do
      public? true
      constraints max_length: 200, trim?: true
    end

    timestamps()
  end

  relationships do
    belongs_to :patient, ClinicDemo.Scheduling.Patient do
      description "The animal being seen."
      allow_nil? false
      public? true
    end

    belongs_to :clinician, ClinicDemo.Scheduling.Clinician do
      description "Who is seeing them."
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :ends_at,
              :utc_datetime,
              expr(datetime_add(scheduled_at, duration_minutes, :minute)) do
      public? true
    end

    calculate :open?, :boolean, expr(status in [:scheduled, :checked_in]) do
      description "Still occupies a slot on the schedule."
      public? true
    end

    # Grid labels for the schedule surfaces: names instead of bare UUIDs.
    calculate :patient_label, :string, expr(patient.name) do
      public? true
    end

    calculate :clinician_label, :string, expr(clinician.full_name) do
      public? true
    end

    # The board's lane key: the one dimension the kanban cards sort by. It
    # reads the same state the process engine moves (status + triage
    # urgency), so a lane move IS a state transition — never a parallel
    # tracking field that can drift from the engine.
    calculate :board_lane,
              :string,
              expr(
                cond do
                  status == :checked_in -> "in_visit"
                  status == :completed -> "discharged"
                  status in [:cancelled, :no_show] -> "closed"
                  status == :scheduled and is_nil(triage_urgency) -> "intake"
                  status == :scheduled and triage_urgency == :routine -> "low"
                  status == :scheduled and triage_urgency == :soon -> "medium"
                  status == :scheduled and triage_urgency in [:urgent, :emergency] -> "high"
                  true -> "closed"
                end
              ) do
      public? true
    end
  end

  # The one authority on the visit lifecycle: which statuses exist, which one
  # a visit starts in, and which moves are legal. The actions below drive the
  # machine with `transition_state/1`; a move the declaration does not allow
  # fails with `NoMatchingTransition`, the same refusal the old per-action
  # CurrentStatusIn validations produced but now derived from this one map.
  state_machine do
    # The lifecycle lives in the resource's own `:status` attribute (declared
    # in the attributes block, with its one_of constraint and default) —
    # pointed at explicitly rather than the extension's `:state` default.
    state_attribute(:status)

    initial_states([:scheduled, :checked_in, :completed, :cancelled, :no_show])
    default_initial_state(:scheduled)

    transitions do
      transition(:check_in, from: :scheduled, to: :checked_in)
      transition(:complete, from: :checked_in, to: :completed)
      transition(:cancel, from: [:scheduled, :checked_in], to: :cancelled)
      transition(:mark_no_show, from: :scheduled, to: :no_show)
    end
  end

  actions do
    default_accept []
    defaults [:read]

    read :in_window do
      description "Everything on the schedule between two instants, earliest first."

      argument :from, :utc_datetime do
        description "Inclusive lower bound."
        allow_nil? false
      end

      argument :to, :utc_datetime do
        description "Exclusive upper bound."
        allow_nil? false
      end

      filter expr(scheduled_at >= ^arg(:from) and scheduled_at < ^arg(:to))

      prepare build(sort: [scheduled_at: :asc])
    end

    create :book do
      description "Put a new appointment on the schedule."

      accept [:scheduled_at, :duration_minutes, :reason, :severity]

      argument :patient_id, :uuid do
        description "An existing patient. Exactly one of this and :patient."
        allow_nil? true
      end

      argument :patient, :map do
        description """
        A new patient to register on the spot, as the intake form collects
        them. The map is created through `Patient.register`, so that
        action's validations (the owner-email format, no future dates of
        birth) run on the nested input exactly as they do on the patients
        surface.
        """

        allow_nil? true
      end

      argument :clinician_id, :uuid do
        description "An existing, active clinician."
        allow_nil? false
      end

      # The two ways of naming the patient. Each manage only fires when its
      # argument was actually supplied (the `where` guards), and the
      # validation below makes the either/or a hard contract: exactly one.
      change manage_relationship(:patient_id, :patient, type: :append),
        where: [present(:patient_id)]

      change manage_relationship(:patient, :patient,
               type: :create,
               on_no_match: {:create, :register}
             ),
             where: [present(:patient)]

      # The either/or is a hard contract, not whichever write landed last.
      validate {ExactlyOneOf, arguments: [:patient_id, :patient]}

      change manage_relationship(:clinician_id, :clinician, type: :append)

      # Booking is what starts the visit process. Everything the appointment
      # goes through after this -- triage, check-in, the lab wait, discharge --
      # is a token walking `priv/processes/appointment_visit.bpmn`.
      change StartVisitProcess

      validate {NotInThePast, attribute: :scheduled_at}
    end

    update :reschedule do
      description "Move an existing appointment. Only open appointments can move."

      # Not a state transition — the status does not change, the slot does.
      # The precondition stays an explicit validation, outside the machine.

      # Reads the prior status, so it cannot run as a single atomic statement.
      require_atomic? false

      accept []

      argument :scheduled_at, :utc_datetime do
        allow_nil? false
      end

      validate {CurrentStatusIn, from: [:scheduled, :checked_in]}
      validate {NotInThePast, attribute: :scheduled_at}

      change set_attribute(:scheduled_at, arg(:scheduled_at))
    end

    update :check_in do
      description "The animal has arrived."

      require_atomic? false

      accept []

      change {ComplianceGuard, transition_to: :checked_in}
      change transition_state(:checked_in)
    end

    update :complete do
      description "The visit happened. Clinical notes are mandatory."

      require_atomic? false

      accept []

      argument :notes, :string do
        description "What was found and what was done."
        allow_nil? false
        constraints min_length: 10, max_length: 4000, trim?: true
      end

      change {ComplianceGuard, transition_to: :completed}
      change set_attribute(:notes, arg(:notes))
      change transition_state(:completed)
    end

    update :cancel do
      description "Called off before it happened."

      require_atomic? false

      accept []

      argument :reason, :string do
        allow_nil? false
        constraints min_length: 3, max_length: 200, trim?: true
      end

      change {ComplianceGuard, transition_to: :cancelled}
      change set_attribute(:cancellation_reason, arg(:reason))
      change transition_state(:cancelled)
    end

    update :record_triage do
      description """
      Write down how urgent the triage decision said this is.

      The decision decides; this action acts. Splitting them that way is what
      keeps the rule in one place: every caller that wants an urgency written
      comes through here, and the only thing that knows how to work one out is
      the DMN table in `priv/decisions/appointment_triage.dmn`.
      """

      require_atomic? false

      accept []

      argument :urgency, :atom do
        description "The decision's answer, not the caller's opinion."
        allow_nil? false
        constraints one_of: [:emergency, :urgent, :soon, :routine]
      end

      # Not a state transition either — recording the triage answer writes
      # `triage_urgency`, not `status`, so it stays outside the machine and
      # keeps its explicit precondition.
      validate {CurrentStatusIn, from: [:scheduled, :checked_in]}

      change set_attribute(:triage_urgency, arg(:urgency))
    end

    update :mark_no_show do
      description "The slot came and went and nobody arrived."

      require_atomic? false

      accept []

      change {ComplianceGuard, transition_to: :no_show}
      change transition_state(:no_show)
    end

    update :discharge do
      description """
      The animal has gone home.

      Only a written-up visit can be discharged, and that guard is the point:
      the visit process calls this action like any other caller and is refused
      by the same rule. A process that could set `discharged_at` on an
      unfinished visit would be a second way to close one.
      """

      require_atomic? false

      accept []

      # Not a state transition: discharge writes `discharged_at` and leaves
      # `:status` alone (a completed visit stays completed at home), so the
      # machine does not speak for it — the precondition stays explicit.
      validate {CurrentStatusIn, from: [:completed]}

      change set_attribute(:discharged_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action_type(:read) do
      description "The schedule is readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may change the schedule."
      authorize_if actor_present()
    end
  end
end
