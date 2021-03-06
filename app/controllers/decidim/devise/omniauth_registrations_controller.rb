# frozen_string_literal: true

module Decidim
  module Devise
    # This controller customizes the behaviour of Devise::Omniauthable.
    class OmniauthRegistrationsController < ::Devise::OmniauthCallbacksController
      include FormFactory
      include Decidim::DeviseControllers

      def new
        @form = form(OmniauthRegistrationForm).from_params(params[:user])
      end

      def create
        form_params = user_params_from_oauth_hash || params[:user]
        @form = form(OmniauthRegistrationForm).from_params(form_params)
        @form.email ||= verified_email

        CreateOmniauthRegistration.call(@form, verified_email) do
          on(:ok) do |user|
            if user.active_for_authentication?
              sign_in_and_redirect user, event: :authentication
              set_flash_message :notice, :success, kind: provider_name(@form.provider)
            else
              expire_data_after_sign_in!
              redirect_to root_path
              flash[:notice] = t("devise.registrations.signed_up_but_unconfirmed")
            end
          end

          on(:invalid) do
            set_flash_message :notice, :success, kind: provider_name(@form.provider)
            render :new
          end

          on(:error) do |user|
            if user.errors[:email]
              set_flash_message :alert, :failure, kind: provider_name(@form.provider), reason: t("decidim.devise.omniauth_registrations.create.email_already_exists")
            end

            render :new
          end
        end
      end

      def after_sign_in_path_for(user)
        if !pending_redirect?(user) && first_login_and_not_authorized?(user)
          authorizations_path
        else
          super
        end
      end

      # Calling the `stored_location_for` method removes the key, so in order
      # to check if there's any pending redirect after login I need to call
      # this method and use the value to set a pending redirect. This is the
      # only way to do this without checking the session directly.
      def pending_redirect?(user)
        store_location_for(user, stored_location_for(user))
      end

      def first_login_and_not_authorized?(user)
        user.is_a?(User) && user.sign_in_count == 1 && Decidim.authorization_handlers.any?
      end

      def action_missing(action_name)
        return send(:create) if devise_mapping.omniauthable? && User.omniauth_providers.include?(action_name.to_sym)
        raise AbstractController::ActionNotFound, "The action '#{action_name}' could not be found for Decidim::Devise::OmniauthCallbacksController"
      end

      # Customized tunnistamo callback to bypass setting up the user parameters
      def tunnistamo
        info = oauth_data[:info] || {}

        # Fetch the nickname passed form Tunnistamo
        nickname = oauth_nickname

        identity = Decidim::Identity.find_by(uid: oauth_data[:uid])
        if identity
          user = identity.user
          if user
            # Update user if it alreadt existed
            user.update(
              email: info[:email],
              name: oauth_name,
            )

            set_flash_message :notice, :success, kind: provider_name(oauth_data[:provider])
            handle_tunnistamo_success user
            return
          else
            identity.destroy!
          end
        end

        @form = form(OmniauthRegistrationForm).from_params({
          uid: oauth_data[:uid],
          provider: oauth_data[:provider],
          oauth_signature: OmniauthRegistrationForm.create_signature(oauth_data[:provider], oauth_data[:uid]),
          email: info[:email],
          name: oauth_name,
          nickname: oauth_nickname,
        })

        CreateOmniauthRegistration.call(@form, verified_email) do
          on(:ok) do |user|
            mark_tos_accepted user
            set_flash_message :notice, :success, kind: provider_name(@form.provider)
            handle_tunnistamo_success user
          end

          on(:invalid) do
            set_flash_message :notice, :success, kind: provider_name(@form.provider)
            redirect_to root_path
          end

          on(:error) do |user|
            if user.errors[:email]
              set_flash_message :alert, :failure, kind: provider_name(@form.provider), reason: t("decidim.devise.omniauth_registrations.create.email_already_exists")
            end

            redirect_to root_path
          end
        end
      end

      private

      def handle_tunnistamo_success(user)
        if user.active_for_authentication?
          sign_in_and_redirect user, event: :authentication
        else
          expire_data_after_sign_in!
          redirect_to root_path
          flash[:notice] = t("devise.registrations.signed_up_but_unconfirmed")
        end
      end

      def oauth_data
        @oauth_data ||= oauth_hash.slice(:provider, :uid, :info)
      end

      # Private: Create form params from omniauth hash
      # Since we are using trusted omniauth data we are generating a valid signature.
      def user_params_from_oauth_hash
        return nil unless request.env["omniauth.auth"]
        {
          provider: oauth_data[:provider],
          uid: oauth_data[:uid],
          name: oauth_data[:info][:name],
          oauth_signature: OmniauthRegistrationForm.create_signature(oauth_data[:provider], oauth_data[:uid])
        }
      end

      def mark_tos_accepted(user)
        if user.accepted_tos_version.nil?
          user.update(
            accepted_tos_version: current_organization.tos_version,
          )
        end
      end

      def oauth_name
        oauth_data.dig(:info, :name) || oauth_nickname || verified_email.split('@').first
      end

      def oauth_nickname
        # Fetch the nickname passed form Tunnistamo
        oauth_data.dig(:info, :nickname) || oauth_hash.dig(:extra, :raw_info, :nickname)
      end

      def verified_email
        @verified_email ||= oauth_data.dig(:info, :email)
      end

      def provider_name(provider)
        if provider.to_sym == :tunnistamo
          "Helsinki - Tunnistamo"
        else
          provider.capitalize
        end
      end

      def oauth_hash
        raw_hash = request.env["omniauth.auth"] || session[:oauth_hash]
        return {} unless raw_hash

        raw_hash.deep_symbolize_keys
      end
    end
  end
end
