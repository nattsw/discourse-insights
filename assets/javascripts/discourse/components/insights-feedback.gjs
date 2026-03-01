import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class InsightsFeedback extends Component {
  @service currentUser;

  @tracked comment = "";
  @tracked submitting = false;
  @tracked submitted = false;

  get submitDisabled() {
    return this.submitting || !this.comment.trim();
  }

  @action
  updateComment(event) {
    this.comment = event.target.value;
  }

  @action
  async submit() {
    if (this.submitDisabled) {
      return;
    }

    this.submitting = true;
    try {
      await ajax("/insights/feedback", {
        type: "POST",
        data: { comment: this.comment.trim() },
      });
      this.submitted = true;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.submitting = false;
    }
  }

  <template>
    {{#if this.currentUser}}
      <div class="insights-feedback">
        {{#if this.submitted}}
          <p class="insights-feedback__thanks">
            {{i18n "discourse_insights.feedback.thanks"}}
          </p>
        {{else}}
          <textarea
            class="insights-feedback__textarea"
            placeholder={{i18n "discourse_insights.feedback.placeholder"}}
            value={{this.comment}}
            {{on "input" this.updateComment}}
          ></textarea>
          <div class="insights-feedback__actions">
            <DButton
              @action={{this.submit}}
              @label="discourse_insights.feedback.submit"
              @disabled={{this.submitDisabled}}
              @isLoading={{this.submitting}}
              class="btn-default insights-feedback__submit"
            />
          </div>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
