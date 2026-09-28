defmodule ClinicDemoWeb.A2ui.EventUI do
  @moduledoc """
  The audit feed: rows of the `ash_events` event log, newest first.

  Read-only by construction — the log's writer is ash_events' own machinery
  (every story resource's wrapped action appends in its transaction), not
  this surface. If the log is ever empty (a fresh, unseeded database), the
  LiveView around this surface says so honestly.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Events.Event
    surface_id "clinic_events"
    title "Audit events"
    record_label("event")
    spec_version "0.9.1"

    query :default do
      # No search_fields: the log's text columns (`action`, `resource`,
      # `action_type`) are ash_events' atom-typed contract, and the a2ui
      # search is a case-insensitive contains over string attributes only —
      # so the feed is a paged, sortable surface rather than a searched one.
      sortable [:occurred_at, :resource, :action]
      default_sort occurred_at: :desc
      page_size 25
    end

    component :table do
      fields [:what, :action_type, :record_id, :user_id, :occurred_at]
      read_action :read
      query :default

      # The action_type carries 20+ audit values with no tone vocabulary —
      # a badge there would be meaningless color (CLIN-10 finding #13), so
      # it rides the meta row as metadata: white-chip reads, no fill
      # pretending to mean something. `what` stays the title; the feed's
      # scannability is the timeline, not the type column.
      row_layout do
        title :what
        meta [:action_type, :record_id, :user_id, :occurred_at]
        columns 2
      end
    end

    field :what do
      label "Event"
    end

    field :occurred_at do
      label "When"
    end

    field :record_id do
      label "Record"
    end

    field :user_id do
      label "Actor"
    end
  end
end
