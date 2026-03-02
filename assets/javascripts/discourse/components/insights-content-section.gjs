import Component from "@glimmer/component";
import number from "discourse/helpers/number";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";

export default class InsightsContentSection extends Component {
  get topTopics() {
    return (this.args.data?.top_topics ?? []).map((topic) => ({
      ...topic,
      url: getURL(`/t/-/${topic.topic_id}`),
    }));
  }

  get searchTerms() {
    return this.args.data?.search_terms ?? [];
  }

  <template>
    <div class="insights-card">
      <div class="insights-card__title">{{i18n
          "discourse_insights.explore.top_topics"
        }}</div>
      <table class="insights-rank-table">
        <tbody>
          {{#each this.topTopics as |topic|}}
            <tr>
              <td class="insights-rank-table__name">
                <a
                  href={{topic.url}}
                  class="insights-topic-link"
                >{{topic.title}}</a>
              </td>
              <td class="insights-rank-table__value">{{number topic.views}}</td>
            </tr>
          {{/each}}
        </tbody>
      </table>
    </div>
    <div class="insights-card">
      <div class="insights-card__title">{{i18n
          "discourse_insights.explore.search_terms"
        }}</div>
      <table class="insights-rank-table">
        <tbody>
          {{#each this.searchTerms as |term|}}
            <tr>
              <td class="insights-rank-table__name">
                {{term.term}}
                {{#if term.content_gap}}
                  <span
                    class="insights-badge insights-badge--gap"
                    title={{i18n
                      "discourse_insights.explore.content_gap_tooltip"
                    }}
                  >{{i18n
                      "discourse_insights.explore.content_gap_badge"
                    }}</span>
                {{/if}}
              </td>
              <td class="insights-rank-table__value">{{term.count}}</td>
              <td class="insights-rank-table__meta">{{i18n
                  "discourse_insights.explore.ctr"
                  value=term.ctr
                }}</td>
            </tr>
          {{/each}}
        </tbody>
      </table>
    </div>
  </template>
}
