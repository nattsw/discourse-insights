import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { htmlSafe } from "@ember/template";
import number from "discourse/helpers/number";
import { i18n } from "discourse-i18n";

const VISIBLE_ROWS = 5;

function formatTrendText(pct) {
  if (pct > 0) {
    return `↑ ${pct}%`;
  }
  if (pct < 0) {
    return `↓ ${Math.abs(pct)}%`;
  }
  return "— flat";
}

function trendCssClass(pct) {
  if (pct > 2) {
    return "insights-trend--up";
  }
  if (pct < -2) {
    return "insights-trend--down";
  }
  return "insights-trend--flat";
}

export default class InsightsCategoriesSection extends Component {
  @tracked expanded = false;

  get categories() {
    return (this.args.data?.categories ?? []).map((cat) => ({
      ...cat,
      dotStyle: htmlSafe(`background-color: #${cat.color}`),
      trendText: formatTrendText(cat.trend_pct),
      trendClass: trendCssClass(cat.trend_pct),
    }));
  }

  get visibleCategories() {
    if (this.expanded) {
      return this.categories;
    }
    return this.categories.slice(0, VISIBLE_ROWS);
  }

  get hasMore() {
    return this.categories.length > VISIBLE_ROWS;
  }

  @action
  toggle() {
    this.expanded = !this.expanded;
  }

  <template>
    <div class="insights-card">
      <table class="insights-cat-table">
        <thead>
          <tr>
            <th>{{i18n "discourse_insights.explore.category"}}</th>
            <th>{{i18n "discourse_insights.explore.page_views"}}</th>
            <th>{{i18n "discourse_insights.explore.new_topics"}}</th>
            <th>{{i18n "discourse_insights.explore.replies"}}</th>
            <th>{{i18n "discourse_insights.explore.trend"}}</th>
          </tr>
        </thead>
        <tbody>
          {{#each this.visibleCategories as |cat|}}
            <tr>
              <td>
                <span class="insights-cat-dot" style={{cat.dotStyle}}></span>
                {{cat.name}}
              </td>
              <td>{{number cat.page_views}}</td>
              <td>{{cat.new_topics}}</td>
              <td>{{cat.replies}}</td>
              <td>
                <span class={{cat.trendClass}}>{{cat.trendText}}</span>
              </td>
            </tr>
          {{/each}}
          {{#if this.hasMore}}
            <tr
              class="insights-cat-table__more"
              role="button"
              {{on "click" this.toggle}}
            >
              <td colspan="5">
                <span
                  class="insights-cat-table__more-icon
                    {{if this.expanded 'insights-cat-table__more-icon--up'}}"
                >›</span>
              </td>
            </tr>
          {{/if}}
        </tbody>
      </table>
    </div>
  </template>
}
