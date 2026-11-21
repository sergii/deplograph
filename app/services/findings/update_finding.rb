module Findings
  class UpdateFinding
    class TransitionDenied < StandardError; end

    MUTABLE_STATUSES = %w[open acknowledged investigating verification_pending dismissed].freeze

    def call(finding:, actor:, status: nil, note: nil, assigned_to_id: :unchanged,
             next_action: :unchanged, priority: nil, severity: nil, can_classify: false)
      unless Membership.exists?(organization_id: finding.organization_id, user_id: actor.id)
        raise TransitionDenied, "Actor is not in this organization"
      end
      raise TransitionDenied, "Resolution requires independent verified evidence" if status == "resolved"
      raise TransitionDenied, "Invalid status" if status.present? && !MUTABLE_STATUSES.include?(status)
      raise TransitionDenied, "Invalid note" if note.present? &&
        (!note.is_a?(String) || note.length > 2_000)
      raise TransitionDenied, "Only owner/admin can change priority and severity" if
        !can_classify && (priority.present? || severity.present?)
      if priority.present? && !DriftFinding::PRIORITIES.include?(priority)
        raise TransitionDenied, "Invalid priority"
      end
      if severity.present? && !DriftFinding::SEVERITIES.include?(severity)
        raise TransitionDenied, "Invalid severity"
      end

      finding.with_lock do
        previous = finding.status
        if status == "dismissed" && previous != "dismissed" && note.to_s.strip.empty?
          raise TransitionDenied, "Dismissal requires an explanation"
        end

        if status.present? && status != previous
          finding.update!(status: status)
          finding.drift_finding_events.create!(
            actor: actor, action: "status_changed",
            from_status: previous, to_status: status, note: note.presence
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

        if next_action != :unchanged && next_action != finding.next_action
          if next_action && (!next_action.is_a?(String) || next_action.length > 1_500)
            raise TransitionDenied, "Invalid next action"
          end
          finding.update!(next_action: next_action)
          finding.drift_finding_events.create!(actor: actor, action: "next_action_changed",
            note: "Next action updated")
        end

        %i[priority severity].each do |field|
          new_value = field == :priority ? priority : severity
          next if new_value.blank? || finding.public_send(field) == new_value

          old_value = finding.public_send(field)
          finding.update!(field => new_value)
          finding.drift_finding_events.create!(
            actor: actor, action: "#{field}_changed",
            note: "#{field.to_s.humanize}: #{old_value} -> #{new_value}"
          )
        end
      end
      finding
    end
  end
end
