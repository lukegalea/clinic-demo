defmodule ClinicDemoWeb.A2ui.EventUI do
  @moduledoc """
  The audit feed: rows of the `ash_events` event log, newest first.

  Read-only by construction — the underlying resource has no write actions,
  and the log's writer is the (deferred) event projector, not this
  application. Until that runs, this surface shows an honest empty state:
  the guard path here is synchronous and appends nothing today.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Events.Event
    surface_id "clinic_events"
    title "Audit events"
    record_label("event")
    spec_version "0.9.1"

    query :default do
      search_fields [:action, :resource, :action_type]
      sortable [:occurred_at, :resource, :action]
      default_sort occurred_at: :desc
      page_size 25
    end

    component :table do
      fields [:what, :action_type, :record_id, :user_id, :occurred_at]
      read_action :read
      query :default

      row_layout do
        title :what
        badge :action_type
        meta [:record_id, :occurred_at]
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
