import { fn } from "@ember/helper";
import DButton from "discourse/components/d-button";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

const PERIOD_OPTIONS = [
  { id: "7d", label: i18n("discourse_insights.periods.7d") },
  { id: "30d", label: i18n("discourse_insights.periods.30d") },
  { id: "3m", label: i18n("discourse_insights.periods.3m") },
];

const InsightsHeader = <template>
  <div class="insights-header">
    <h2 class="insights-header__title">{{i18n "discourse_insights.title"}}</h2>
    <div class="insights-header__controls">
      {{#each PERIOD_OPTIONS as |opt|}}
        <DButton
          class={{if
            (eq @period opt.id)
            "btn-primary insights-period-btn"
            "btn-default insights-period-btn"
          }}
          @action={{fn @onChangePeriod opt.id}}
          @translatedLabel={{opt.label}}
        />
      {{/each}}
      <DButton
        class={{if
          @isCustomPeriod
          "btn-primary insights-period-btn"
          "btn-default insights-period-btn"
        }}
        @action={{@onOpenCustomDateRange}}
        @icon="calendar-days"
        @translatedLabel={{if
          @isCustomPeriod
          @customDateLabel
          (i18n "discourse_insights.periods.custom")
        }}
      />
      <DButton
        class="btn-default btn-small btn-icon no-text insights-refresh-btn"
        @action={{@onRefresh}}
        @icon="arrows-rotate"
        @title="discourse_insights.refresh_tooltip"
        @disabled={{@loading}}
      />
    </div>
  </div>
</template>;

export default InsightsHeader;
