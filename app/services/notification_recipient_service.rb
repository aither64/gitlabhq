#
# Used by NotificationService to determine who should receive notification
#
class NotificationRecipientService
  attr_reader :project

  def self.notification_setting_for_user_project(user, project)
    project_setting = project && user.notification_settings_for(project)

    return project_setting unless project_setting.nil? || project_setting.global?

    group_setting = project&.group && user.notification_settings_for(project.group)

    return group_setting unless group_setting.nil? || group_setting.global?

    user.global_notification_setting
  end

  def initialize(project)
    @project = project
  end

  module Builder
    class Base
      def initialize(*)
        raise 'abstract'
      end

      def build
        raise 'abstract'
      end

      def build(*)
        raise 'abstract'
      end

      # Remove users with disabled notifications from array
      # Also remove duplications and nil recipients
      def reject_muted_users(users)
        reject_users(users, :disabled)
      end

      protected

      # Ensure that if we modify this array, we aren't modifying the memoised
      # participants on the target.
      def participants(target, user)
        return unless target.respond_to?(:participants)

        target.participants(user).dup
      end

      # Get project/group users with CUSTOM notification level
      def add_custom_notifications(recipients, action)
        user_ids = []

        # Users with a notification setting on group or project
        user_ids += user_ids_notifiable_on(project, :custom, action)
        user_ids += user_ids_notifiable_on(project.group, :custom, action)

        # Users with global level custom
        user_ids_with_project_level_global = user_ids_notifiable_on(project, :global)
        user_ids_with_group_level_global   = user_ids_notifiable_on(project.group, :global)

        global_users_ids = user_ids_with_project_level_global.concat(user_ids_with_group_level_global)
        user_ids += user_ids_with_global_level_custom(global_users_ids, action)

        recipients.concat(User.find(user_ids))
      end

      def add_project_watchers(recipients)
        recipients.concat(project_watchers).compact
      end

      # Get project users with WATCH notification level
      def project_watchers
        project_members_ids = user_ids_notifiable_on(project)

        user_ids_with_project_global = user_ids_notifiable_on(project, :global)
        user_ids_with_group_global   = user_ids_notifiable_on(project.group, :global)

        user_ids = user_ids_with_global_level_watch((user_ids_with_project_global + user_ids_with_group_global).uniq)

        user_ids_with_project_setting = select_project_members_ids(project, user_ids_with_project_global, user_ids)
        user_ids_with_group_setting = select_group_members_ids(project.group, project_members_ids, user_ids_with_group_global, user_ids)

        User.where(id: user_ids_with_project_setting.concat(user_ids_with_group_setting).uniq).to_a
      end

      # Remove users with notification level 'Mentioned'
      def reject_mention_users(users)
        reject_users(users, :mention)
      end

      def add_subscribed_users(recipients, target)
        return recipients unless target.respond_to? :subscribers

        recipients + target.subscribers(project)
      end

      def user_ids_notifiable_on(resource, notification_level = nil, action = nil)
        return [] unless resource

        if notification_level
          settings = resource.notification_settings.where(level: NotificationSetting.levels[notification_level])
          settings = settings.select { |setting| setting.event_enabled?(action) } if action.present?
          settings.map(&:user_id)
        else
          resource.notification_settings.pluck(:user_id)
        end
      end

      # Build a list of user_ids based on project notification settings
      def select_project_members_ids(project, global_setting, user_ids_global_level_watch)
        user_ids = user_ids_notifiable_on(project, :watch)

        # If project setting is global, add to watch list if global setting is watch
        global_setting.each do |user_id|
          if user_ids_global_level_watch.include?(user_id)
            user_ids << user_id
          end
        end

        user_ids
      end

      # Build a list of user_ids based on group notification settings
      def select_group_members_ids(group, project_members, global_setting, user_ids_global_level_watch)
        uids = user_ids_notifiable_on(group, :watch)

        # Group setting is watch, add to user_ids list if user is not project member
        user_ids = []
        uids.each do |user_id|
          if project_members.exclude?(user_id)
            user_ids << user_id
          end
        end

        # Group setting is global, add to user_ids list if global setting is watch
        global_setting.each do |user_id|
          if project_members.exclude?(user_id) && user_ids_global_level_watch.include?(user_id)
            user_ids << user_id
          end
        end

        user_ids
      end

      def user_ids_with_global_level_watch(ids)
        settings_with_global_level_of(:watch, ids).pluck(:user_id)
      end

      def user_ids_with_global_level_custom(ids, action)
        settings = settings_with_global_level_of(:custom, ids)
        settings = settings.select { |setting| setting.event_enabled?(action) }
        settings.map(&:user_id)
      end

      def settings_with_global_level_of(level, ids)
        NotificationSetting.where(
          user_id: ids,
          source_type: nil,
          level: NotificationSetting.levels[level]
        )
      end

      # Reject users which has certain notification level
      #
      # Example:
      #   reject_users(users, :watch, project)
      #
      def reject_users(users, level)
        level = level.to_s

        unless NotificationSetting.levels.keys.include?(level)
          raise 'Invalid notification level'
        end

        users = users.to_a.compact.uniq

        users.reject do |user|
          setting = NotificationRecipientService.notification_setting_for_user_project(user, project)
          setting.present? && setting.level == level
        end
      end

      def reject_unsubscribed_users(recipients, target)
        return recipients unless target.respond_to? :subscriptions

        recipients.reject do |user|
          subscription = target.subscriptions.find_by_user_id(user.id)
          subscription && !subscription.subscribed
        end
      end

      def reject_users_without_access(recipients, target)
        recipients = recipients.select { |u| u.can?(:receive_notifications) }

        ability = case target
                  when Issuable
                    :"read_#{target.to_ability_name}"
                  when Ci::Pipeline
                    :read_build # We have build trace in pipeline emails
                  end

        return recipients unless ability

        recipients.select do |user|
          user.can?(ability, target)
        end
      end

      def add_labels_subscribers(recipients, target, labels: nil)
        return recipients unless target.respond_to? :labels

        (labels || target.labels).each do |label|
          recipients += label.subscribers(project)
        end

        recipients
      end

      # Build event key to search on custom notification level
      # Check NotificationSetting::EMAIL_EVENTS
      def build_custom_key(action, object)
        "#{action}_#{object.class.model_name.name.underscore}".to_sym
      end
    end

    class Default < Base
      attr_reader :project
      attr_reader :target
      attr_reader :current_user
      attr_reader :action
      attr_reader :previous_assignee
      attr_reader :skip_current_user
      def initialize(project, target, current_user, action:, previous_assignee: nil, skip_current_user: true)
        @project = project
        @target = target
        @current_user = current_user
        @action = action
        @previous_assignee = previous_assignee
        @skip_current_user = skip_current_user
      end

      def build
        custom_action = build_custom_key(action, target)

        recipients = participants(target, current_user)
        recipients = add_project_watchers(recipients)
        recipients = add_custom_notifications(recipients, custom_action)
        recipients = reject_mention_users(recipients)

        # Re-assign is considered as a mention of the new assignee so we add the
        # new assignee to the list of recipients after we rejected users with
        # the "on mention" notification level
        case custom_action
        when :reassign_merge_request
          recipients << previous_assignee if previous_assignee
          recipients << target.assignee
        when :reassign_issue
          previous_assignees = Array(previous_assignee)
          recipients.concat(previous_assignees)
          recipients.concat(target.assignees)
        end

        recipients = reject_muted_users(recipients)
        recipients = add_subscribed_users(recipients, target)

        if [:new_issue, :new_merge_request].include?(custom_action)
          recipients = add_labels_subscribers(recipients, target)
        end

        recipients = reject_unsubscribed_users(recipients, target)
        recipients = reject_users_without_access(recipients, target)

        recipients.delete(current_user) if skip_current_user && !current_user.notified_of_own_activity?

        recipients.uniq
      end
    end

    class Pipeline < Base
      attr_reader :project
      attr_reader :target
      attr_reader :current_user
      attr_reader :action
      def initialize(project, target, current_user, action:)
        @project = project
        @target = target
        @current_user = current_user
        @action = action
      end

      def build
        return [] unless current_user

        custom_action =
          case action.to_s
          when 'failed'
            :failed_pipeline
          when 'success'
            :success_pipeline
          end

        notification_setting = NotificationRecipientService.notification_setting_for_user_project(current_user, target.project)

        return [] if notification_setting.mention? || notification_setting.disabled?

        return [] if notification_setting.custom? && !notification_setting.event_enabled?(custom_action)

        return [] if (notification_setting.watch? || notification_setting.participating?) && NotificationSetting::EXCLUDED_WATCHER_EVENTS.include?(custom_action)

        reject_users_without_access([current_user], target)
      end
    end

    class Relabeled < Base
      attr_reader :project
      attr_reader :target
      attr_reader :current_user
      attr_reader :labels
      def initialize(project, target, current_user, labels:)
        @project = project
        @target = target
        @current_user = current_user
        @labels = labels
      end

      def build
        recipients = add_labels_subscribers([], target, labels: labels)
        recipients = reject_unsubscribed_users(recipients, target)
        recipients = reject_users_without_access(recipients, target)
        recipients.delete(current_user) unless current_user.notified_of_own_activity?
        recipients.uniq
      end
    end

    class NewNote < Base
      attr_reader :project
      attr_reader :note
      attr_reader :target
      def initialize(project, note)
        @project = project
        @note = note
        @target = note.noteable
      end

      def build(note)
        ability, subject = if note.for_personal_snippet?
                             [:read_personal_snippet, note.noteable]
                           else
                             [:read_project, note.project]
                           end

        mentioned_users = note.mentioned_users.select { |user| user.can?(ability, subject) }

        # Add all users participating in the thread (author, assignee, comment authors)
        recipients = participants(target, note.author) || mentioned_users

        unless note.for_personal_snippet?
          # Merge project watchers
          recipients = add_project_watchers(recipients)

          # Merge project with custom notification
          recipients = add_custom_notifications(recipients, :new_note)
        end

        # Reject users with Mention notification level, except those mentioned in _this_ note.
        recipients = reject_mention_users(recipients - mentioned_users)
        recipients = recipients + mentioned_users

        recipients = reject_muted_users(recipients)

        recipients = add_subscribed_users(recipients, note.noteable)
        recipients = reject_unsubscribed_users(recipients, note.noteable)
        recipients = reject_users_without_access(recipients, note.noteable)

        recipients.delete(note.author) unless note.author.notified_of_own_activity?
        recipients.uniq
      end
    end
  end

  def build_recipients(*a)
    Builder::Default.new(@project, *a).build
  end

  def build_pipeline_recipients(*a)
    Builder::Pipeline.new(@project, *a).build
  end

  def build_relabeled_recipients(*a)
    Builder::Relabeled.new(@project, *a).build
  end

  def build_new_note_recipients(*a)
    Builder::NewNote.new(@project, *a).build
  end
end
