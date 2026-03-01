import Component from "@glimmer/component";
import number from "discourse/helpers/number";
import { i18n } from "discourse-i18n";
import InsightsGeoMap from "./insights-geo-map";

export default class InsightsTrafficSection extends Component {
  get geoBreakdown() {
    return this.args.data?.geo_breakdown ?? [];
  }

  get trafficSources() {
    return this.args.data?.traffic_sources ?? [];
  }

  <template>
    {{#if this.geoBreakdown.length}}
      <div class="insights-card insights-card--full">
        <div class="insights-card__title">{{i18n
            "discourse_insights.explore.geography"
          }}</div>
        <InsightsGeoMap @data={{this.geoBreakdown}} />
      </div>
      <div class="insights-geo-upsell">
        <div class="insights-geo-upsell__text">
          <span class="insights-geo-upsell__title">{{i18n
              "discourse_insights.explore.geo_upsell_title"
            }}</span>
          <span class="insights-geo-upsell__desc">{{i18n
              "discourse_insights.explore.geo_upsell_desc"
            }}</span>
        </div>
        <a
          href="https://discourse.org/enterprise"
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-primary insights-geo-upsell__cta"
        >{{i18n "discourse_insights.explore.geo_upsell_cta"}}</a>
      </div>
    {{/if}}
    <div
      class="insights-explore__grid
        {{if this.geoBreakdown.length 'insights-explore__grid--2'}}"
    >
      <div class="insights-card">
        <div class="insights-card__title">{{i18n
            "discourse_insights.explore.referrers"
          }}</div>
        <table class="insights-rank-table">
          <tbody>
            {{#each this.trafficSources as |source|}}
              <tr>
                <td class="insights-rank-table__name">{{source.domain}}</td>
                <td class="insights-rank-table__value">{{number
                    source.clicks
                  }}</td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      </div>
      {{#if this.geoBreakdown.length}}
        <div class="insights-card">
          <div class="insights-card__title">{{i18n
              "discourse_insights.explore.top_countries"
            }}</div>
          <table class="insights-rank-table">
            <tbody>
              {{#each this.geoBreakdown as |geo|}}
                <tr>
                  <td class="insights-rank-table__name">
                    {{geo.country}}
                  </td>
                  <td class="insights-rank-table__value">{{number
                      geo.count
                    }}</td>
                  <td class="insights-rank-table__meta">{{geo.pct}}%</td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        </div>
      {{/if}}
    </div>
  </template>
}
