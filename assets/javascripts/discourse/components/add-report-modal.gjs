import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class AddReportModal extends Component {
  @tracked queries = null;
  @tracked loading = true;
  @tracked filter = "";

  constructor() {
    super(...arguments);
    this.loadQueries();
  }

  async loadQueries() {
    try {
      const result = await ajax("/insights/reports/available.json");
      this.queries = result.queries;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  get unpinnedQueries() {
    return (this.queries ?? [])
      .filter((q) => !q.pinned)
      .sort((a, b) => {
        if (a.insights !== b.insights) {
          return a.insights ? -1 : 1;
        }
        return a.name.localeCompare(b.name);
      });
  }

  get filteredQueries() {
    const term = this.filter.toLowerCase().trim();
    if (!term) {
      return this.unpinnedQueries;
    }
    return this.unpinnedQueries.filter((q) =>
      q.name.toLowerCase().includes(term)
    );
  }

  @action
  onFilterChange(event) {
    this.filter = event.target.value;
  }

  @action
  async addQuery(queryId) {
    try {
      await ajax("/insights/reports.json", {
        type: "POST",
        data: { query_id: queryId },
      });
      this.args.model.onAdd?.(queryId);
      this.args.closeModal();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  <template>
    <DModal
      class="add-report-modal"
      @title={{i18n "discourse_insights.reports.add_title"}}
      @closeModal={{@closeModal}}
    >
      <:body>
        {{#if this.loading}}
          <div class="add-report-modal__loading">
            <div class="spinner medium"></div>
          </div>
        {{else if this.unpinnedQueries.length}}
          <input
            class="add-report-modal__filter"
            type="text"
            value={{this.filter}}
            placeholder={{i18n
              "discourse_insights.reports.filter_placeholder"
            }}
            {{on "input" this.onFilterChange}}
          />
          {{#if this.filteredQueries.length}}
            <ul class="add-report-modal__list">
              {{#each this.filteredQueries as |query|}}
                <li class="add-report-modal__item">
                  <div class="add-report-modal__info">
                    <span class="add-report-modal__name">
                      {{#if query.insights}}<span
                          class="insights-sparkle-badge"
                          title={{i18n
                            "discourse_insights.reports.insights_query_tooltip"
                          }}
                        >✦</span>{{/if}}
                      {{query.name}}
                    </span>
                    {{#if query.description}}
                      <span
                        class="add-report-modal__desc"
                      >{{query.description}}</span>
                    {{/if}}
                  </div>
                  <DButton
                    class="btn-small btn-primary"
                    @action={{fn this.addQuery query.id}}
                    @icon="plus"
                    @label="discourse_insights.reports.add"
                  />
                </li>
              {{/each}}
            </ul>
          {{else}}
            <p class="add-report-modal__empty">
              {{i18n "discourse_insights.reports.no_matching"}}
            </p>
          {{/if}}
        {{else}}
          <p class="add-report-modal__empty">
            {{i18n "discourse_insights.reports.none_available"}}
          </p>
        {{/if}}
      </:body>
    </DModal>
  </template>
}
