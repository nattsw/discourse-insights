import { on } from "@ember/modifier";

const InsightsExploreSection = <template>
  <div class="insights-explore {{@class}}">
    <button
      type="button"
      class="insights-explore__toggle
        {{if @expanded 'insights-explore__toggle--open'}}"
      aria-expanded={{if @expanded "true" "false"}}
      {{on "click" @onToggle}}
    >
      <span class="insights-explore__icon">›</span>
      <span class="insights-explore__title">
        {{yield to="title"}}
      </span>
      <span class="insights-explore__summary">{{@summary}}</span>
    </button>
    {{#if @expanded}}
      <div class="insights-explore__body {{@bodyClass}}">
        {{yield to="body"}}
      </div>
    {{/if}}
  </div>
</template>;

export default InsightsExploreSection;
