# frozen_string_literal: true

module Decidim
  module Proposals
    # Exposes the proposal resource so users can view and create them.
    class ProposalsController < Decidim::Proposals::ApplicationController
      helper Decidim::WidgetUrlsHelper
      helper ProposalWizardHelper
      include FormFactory
      include FilterResource
      include Orderable
      include Paginable

      before_action :authenticate_user!, only: [:new, :create, :complete]
      before_action :ensure_is_draft, only: [:compare, :complete, :preview, :publish, :edit_draft, :update_draft, :destroy_draft]
      before_action :set_proposal, only: [:show, :edit, :update, :withdraw]
      before_action :edit_form, only: [:edit_draft, :edit]

      # Make the links work in the notice messages
      before_action -> { flash.now[:notice] = flash[:notice].html_safe if flash.delete(:html_safe) && flash[:notice] }

      def index
        @proposals = search
                     .results
                     .published
                     .not_hidden
                     .includes(:category)
                     .includes(:scope)

        @voted_proposals = if current_user
                             ProposalVote.where(
                               author: current_user,
                               proposal: @proposals.pluck(:id)
                             ).pluck(:decidim_proposal_id)
                           else
                             []
                           end

        @proposals = paginate(@proposals)
        @proposals = reorder(@proposals)
      end

      def show
        @report_form = form(Decidim::ReportForm).from_params(reason: "spam")
      end

      def new
        enforce_permission_to :create, :proposal

        @step = :step_1
        if proposal_draft.present?
          redirect_to edit_draft_proposal_path(proposal_draft, component_id: proposal_draft.component.id, question_slug: proposal_draft.component.participatory_space.slug)
        else
          @step = :step_3
          unless @proposal
            @proposal = Proposal.new(component: current_component)
          end
          @form = form_proposal_model
          @form.attachment = form_attachment_new
        end
      end

      def create
        enforce_permission_to :create, :proposal
        @step = :step_3
        @form = form(ProposalForm).from_params(params)

        # Create proposal for the view in case the creation fails. This needs
        # to be outside of the following block since it's a local variable for
        # this class and not the one being accessed inside the block.
        @proposal = Proposal.new(@form.attributes.except(
          :user_group_id,
          :category_id,
          :scope_id,
          :has_address,
          :attachment,
        ).merge({
          component: current_component,
        }))

        # Add coauthorship to the new proposal
        user_group ||= Decidim::UserGroup.find_by(
          organization: current_user.organization,
          id: @form.user_group_id
        )
        @proposal.add_coauthor(current_user, user_group: user_group)

        # We need to initiate the `UpdateProposal` command in order to save the
        # attachements, address and category. The default `CreateProposal` only
        # saves the title and body.
        #
        # Don't worry about the name, it will save a new proposal just fine.
        UpdateProposal.call(@form, current_user, @proposal) do
          on(:ok) do |proposal|
            flash[:notice] = I18n.t("proposals.create.success", scope: "decidim")

            redirect_to fix_path(
              Decidim::ResourceLocatorPresenter.new(proposal).path,
              "/preview"
            )
          end

          on(:invalid) do
            flash.now[:alert] = I18n.t("proposals.create.error", scope: "decidim")
            render :new
          end
        end
      end

      def compare
        @step = :step_2
        @similar_proposals ||= Decidim::Proposals::SimilarProposals
                               .for(current_component, @proposal)
                               .all

        if @similar_proposals.blank?
          flash[:notice] = I18n.t("proposals.proposals.compare.no_similars_found", scope: "decidim")
          redirect_to fix_path(
            Decidim::ResourceLocatorPresenter.new(@proposal).path,
            "/complete"
          )
        end
      end

      def complete
        enforce_permission_to :create, :proposal
        @step = :step_3

        @form = form_proposal_model

        @form.attachment = form_attachment_new
      end

      def preview
        @step = :step_4
      end

      def publish
        @step = :step_4
        PublishProposal.call(@proposal, current_user) do
          on(:ok) do
            flash[:notice] = I18n.t("proposals.publish.success", scope: "decidim")
            flash[:html_safe] = true
            redirect_to proposal_path(@proposal)
          end

          on(:invalid) do
            flash.now[:alert] = I18n.t("proposals.publish.error", scope: "decidim")
            render :edit_draft
          end
        end
      end

      def edit_draft
        @step = :step_3
        enforce_permission_to :edit, :proposal, proposal: @proposal
      end

      def update_draft
        @step = :step_3
        enforce_permission_to :edit, :proposal, proposal: @proposal

        @form = form_proposal_params
        UpdateProposal.call(@form, current_user, @proposal) do
          on(:ok) do |proposal|
            flash[:notice] = I18n.t("proposals.update_draft.success", scope: "decidim")
            redirect_to fix_path(
              Decidim::ResourceLocatorPresenter.new(proposal).path,
              "/preview"
            )
          end

          on(:invalid) do
            flash.now[:alert] = I18n.t("proposals.update_draft.error", scope: "decidim")
            render :edit_draft
          end
        end
      end

      def destroy_draft
        enforce_permission_to :edit, :proposal, proposal: @proposal

        DestroyProposal.call(@proposal, current_user) do
          on(:ok) do
            flash[:notice] = I18n.t("proposals.destroy_draft.success", scope: "decidim")
            redirect_to new_proposal_path
          end

          on(:invalid) do
            flash.now[:alert] = I18n.t("proposals.destroy_draft.error", scope: "decidim")
            render :edit_draft
          end
        end
      end

      def edit
        enforce_permission_to :edit, :proposal, proposal: @proposal
      end

      def update
        enforce_permission_to :edit, :proposal, proposal: @proposal

        @form = form_proposal_params
        UpdateProposal.call(@form, current_user, @proposal) do
          on(:ok) do |proposal|
            flash[:notice] = I18n.t("proposals.update.success", scope: "decidim")
            flash[:html_safe] = true
            redirect_to Decidim::ResourceLocatorPresenter.new(proposal).path
          end

          on(:invalid) do
            flash.now[:alert] = I18n.t("proposals.update.error", scope: "decidim")
            render :edit
          end
        end
      end

      def withdraw
        enforce_permission_to :withdraw, :proposal, proposal: @proposal

        WithdrawProposal.call(@proposal, current_user) do
          on(:ok) do |_proposal|
            flash[:notice] = I18n.t("proposals.update.success", scope: "decidim")
            redirect_to Decidim::ResourceLocatorPresenter.new(@proposal).path
          end
          on(:invalid) do
            flash[:alert] = I18n.t("proposals.update.error", scope: "decidim")
            redirect_to Decidim::ResourceLocatorPresenter.new(@proposal).path
          end
        end
      end

      private

      def search_klass
        ProposalSearch
      end

      def default_filter_params
        {
          search_text: "",
          origin: "all",
          activity: "",
          category_id: "",
          state: "all",
          scope_id: nil,
          related_to: "",
          type: "all"
        }
      end

      def proposal_draft
        Proposal.from_all_author_identities(current_user).not_hidden.where(component: current_component).find_by(published_at: nil)
      end

      def ensure_is_draft
        @proposal = Proposal.not_hidden.where(component: current_component).find_by(id: params[:id])
        if @proposal
          redirect_to Decidim::ResourceLocatorPresenter.new(@proposal).path unless @proposal.draft?
        else
          redirect_to new_proposal_path
        end
      end

      def set_proposal
        @proposal = Proposal.published.not_hidden.where(component: current_component).find(params[:id])
      end

      def form_proposal_params
        form(ProposalForm).from_params(params)
      end

      def form_proposal_model
        form(ProposalForm).from_model(@proposal)
      end

      def form_attachment_new
        form(AttachmentForm).from_params({})
      end

      def edit_form
        form_attachment_model = form(AttachmentForm).from_model(@proposal.attachments.first)
        @form = form_proposal_model
        @form.has_address = !@form.address.nil?
        @form.attachment = form_attachment_model
        @form
      end

      def fix_path(path, suffix)
        parts = path.split(/\?/)

        if parts.length > 1
          parts[0] + suffix + '?' + parts[1]
        else
          parts[0] + suffix
        end
      end
    end
  end
end
