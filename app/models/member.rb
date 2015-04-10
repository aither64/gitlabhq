# == Schema Information
#
# Table name: members
#
#  id                 :integer          not null, primary key
#  access_level       :integer          not null
#  source_id          :integer          not null
#  source_type        :string(255)      not null
#  user_id            :integer          not null
#  notification_level :integer          not null
#  type               :string(255)
#  created_at         :datetime
#  updated_at         :datetime
#  created_by_id      :integer
#  invite_email       :string
#  invite_token       :string
#  invite_accepted_at :datetime
#

class Member < ActiveRecord::Base
  include Sortable
  include Notifiable
  include Gitlab::Access

  belongs_to :created_by, class_name: "User"
  belongs_to :user
  belongs_to :source, polymorphic: true

  validates :user, presence: true, unless: :invite?
  validates :source, presence: true
  validates :user_id, uniqueness: { scope: [:source_type, :source_id], 
                                    message: "already exists in source",
                                    allow_nil: true }
  validates :access_level, inclusion: { in: Gitlab::Access.all_values }, presence: true
  validates :invite_email,  presence: { if: :invite? }, 
                            email: { strict_mode: true, allow_nil: true }, 
                            uniqueness: { scope: [:source_type, :source_id], allow_nil: true }

  scope :invite, -> { where(user_id: nil) }
  scope :non_invite, -> { where("user_id IS NOT NULL") }
  scope :guests, -> { where(access_level: GUEST) }
  scope :reporters, -> { where(access_level: REPORTER) }
  scope :developers, -> { where(access_level: DEVELOPER) }
  scope :masters,  -> { where(access_level: MASTER) }
  scope :owners,  -> { where(access_level: OWNER) }

  before_validation :generate_invite_token, on: :create, if: -> (member) { member.invite_email.present? }
  after_create :send_invite, if: :invite?
  after_create :post_create_hook, unless: :invite?
  after_update :post_update_hook, unless: :invite?
  after_destroy :post_destroy_hook, unless: :invite?

  delegate :name, :username, :email, to: :user, prefix: true

  def self.find_by_invite_token(invite_token)
    invite_token = Devise.token_generator.digest(self, :invite_token, invite_token)
    find_by(invite_token: invite_token)
  end

  def invite?
    self.invite_token.present?
  end

  def accept_invite!(new_user)
    return false unless invite?
    
    self.invite_token = nil
    self.invite_accepted_at = Time.now.utc

    self.user = new_user

    saved = self.save

    after_accept_invite if saved

    saved
  end

  def decline_invite!
    return false unless invite?

    destroyed = self.destroy

    after_decline_invite if destroyed

    destroyed
  end

  def generate_invite_token
    raw, enc = Devise.token_generator.generate(self.class, :invite_token)
    @raw_invite_token = raw
    self.invite_token = enc
  end

  def generate_invite_token!
    generate_invite_token && save(validate: false)
  end

  def resend_invite
    return unless invite?

    generate_invite_token! unless @raw_invite_token

    send_invite
  end

  private

  def send_invite
    # override in subclass
  end

  def post_create_hook
    system_hook_service.execute_hooks_for(self, :create)
  end

  def post_update_hook
    # override in subclass
  end

  def post_destroy_hook
    system_hook_service.execute_hooks_for(self, :destroy)
  end

  def after_accept_invite
    post_create_hook
  end

  def after_decline_invite
    # override in subclass
  end

  def system_hook_service
    SystemHooksService.new
  end

  def notification_service
    NotificationService.new
  end
end
