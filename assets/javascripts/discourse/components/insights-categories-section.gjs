import Component from "@glimmer/component";
import { htmlSafe } from "@ember/template";
import number from "discourse/helpers/number";
import { i18n } from "discourse-i18n";

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
  get categories() {
    return (this.args.data?.categories ?? []).map((cat) => ({
      ...cat,
      dotStyle: htmlSafe(`background-color: #${cat.color}`),
      trendText: formatTrendText(cat.trend_pct),
      trendClass: trendCssClass(cat.trend_pct),
    }));
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
          {{#each this.categories as |cat|}}
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
        </tbody>
      </table>
    </div>
  </template>
}
