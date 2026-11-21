module Findings
  class UpdateFinding
    class TransitionDenied < StandardError; end

    MUTABLE_STATUSES = %w[open acknowledged investigating verification_pending dismissed].freeze

    def call(finding:, actor:, status: nil, note: nil, assigned_to_id: :unchanged,
             next_action: :unchanged)
      raise TransitionDenied, "Actor is not in this organization" unless
        Membership.exists?(organization_id: finding.organization_id, user_id: actor.id)
      raise TransitionDenied, "A new verified runtime observation is required for resolution" if
        status == "resolved"
      if status.present? && !MUTABLE_STATUSES.include?(status)
        raise TransitionDenied, "Invalid finding status"
      end
      if note.present? && (note.length > 2_000 || !note.is_a?(String))
        raise TransitionDenied, "Note exceeds 2000 characters"
      end

      finding.with_lock do
        previous = finding.status
        if status == "dismissed" && previous != "dismissed" && note.to_s.strip.empty?
          raise TransitionDenied, "Dismissing a finding requires an explanation"
        end

        if status.present? && status != previous
          finding.update!(status: status)
          finding.drift_finding_events.create!(
            actor: actor, action: "status_changed", from_status: previous,
            to_status: status, note: note.presence
          )
        elsif note.present?
          finding.drift_finding_events.create!(
            actor: actor, action: "note_added", note: note
          )
        end

        if assigned_to_id != :unchanged
          assignee = assigned_to_id.present? ? finding.organization.users.find(assigned_to_id) : nil
          if finding.assigned_to_id != assignee&.id
            finding.update!(assigned_to: assignee)
            finding.drift_finding_events.create!(
              actor: actor, action: "assigned",
              note: assignee ? "Assigned to member ##{assignee.id}" : "Unassigned"
            )
          end
        end
        finding.update!(next_action: next_action) if next_action != :unchanged
      end
      finding
    end
  end
end
