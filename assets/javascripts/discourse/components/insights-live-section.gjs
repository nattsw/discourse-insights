import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { cancel, later } from "@ember/runloop";
import { htmlSafe } from "@ember/template";
import { ajax } from "discourse/lib/ajax";
import getURL from "discourse/lib/get-url";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import InsightsExploreSection from "./insights-explore-section";

const LIVE_POLL_INTERVAL_MS = 30000;

function humanWindow(minutes) {
  if (minutes < 60) {
    return `${minutes} min`;
  }
  const hours = Math.round(minutes / 60);
  return hours === 1 ? "hour" : `${hours} hours`;
}

export default class InsightsLiveSection extends Component {
  @tracked expanded = false;
  @tracked liveData = null;
  @tracked loading = false;

  _pollTimer = null;

  willDestroy() {
    super.willDestroy(...arguments);
    this._stopPolling();
  }

  get categoriesWindow() {
    return humanWindow(this.liveData?.windows?.categories_minutes ?? 60);
  }

  get chatWindow() {
    return humanWindow(this.liveData?.windows?.chat_minutes ?? 30);
  }

  get activeLabel() {
    const count = this.liveData?.active_users ?? 0;
    return i18n("discourse_insights.live.active_users", { count });
  }

  get composingLabel() {
    const total = this.liveData?.composing?.total ?? 0;
    if (total === 0) {
      return i18n("discourse_insights.live.composing.none");
    }
    return i18n("discourse_insights.live.composing", { count: total });
  }

  get composingDetail() {
    const c = this.liveData?.composing;
    if (!c || c.total === 0) {
      return null;
    }
    return i18n("discourse_insights.live.composing_detail", {
      topic_replies: c.topic_replies,
      chat: c.chat,
    });
  }

  get hotCategories() {
    const cats = this.liveData?.hot_categories ?? [];
    if (!cats.length) {
      return [];
    }
    return cats.slice(0, 5).map((cat) => ({
      ...cat,
      dotStyle: htmlSafe(`background-color:#${cat.color}`),
    }));
  }

  get hotChatChannels() {
    const channels = this.liveData?.hot_chat_channels ?? [];
    if (!channels.length) {
      return [];
    }
    return channels.slice(0, 5).map((ch) => ({
      ...ch,
      dotStyle: htmlSafe(`background-color:#${ch.color}`),
      url: getURL(`/chat/c/${ch.slug || "-"}/${ch.channel_id}`),
    }));
  }

  get stream() {
    return (this.liveData?.activity_stream ?? []).map((item) => {
      let text, url, dotType, countsText;

      if (item.type === "topic_activity") {
        url = getURL(`/t/-/${item.topic_id}`);
        dotType = item.is_new ? "new_topic" : "post";
        const parts = [];
        if (item.replies > 0) {
          parts.push(
            i18n("discourse_insights.live.replies", { count: item.replies })
          );
        }
        if (item.likes > 0) {
          parts.push(
            i18n("discourse_insights.live.likes", { count: item.likes })
          );
        }
        countsText = parts.join(", ");
      } else if (item.type === "new_users") {
        text = i18n("discourse_insights.live.new_users_grouped", {
          count: item.count,
        });
        dotType = "new_user";
      } else if (item.type === "new_user") {
        text = i18n("discourse_insights.live.new_user", {
          username: item.username,
        });
        dotType = "new_user";
      } else if (item.type === "solved") {
        text = i18n("discourse_insights.live.solved", {
          username: item.username,
          title: item.topic_title,
        });
        url = getURL(`/t/-/${item.topic_id}`);
        dotType = "solved";
      }

      return {
        ...item,
        text,
        url,
        dotType,
        countsText,
        relativeTime: moment(item.created_at).fromNow(),
      };
    });
  }

  @action
  toggle() {
    this.expanded = !this.expanded;
    if (this.expanded) {
      this._fetchLiveData();
    } else {
      this._stopPolling();
    }
  }

  async _fetchLiveData() {
    this.loading = !this.liveData;
    try {
      this.liveData = await ajax("/insights/live.json");
    } catch {
      // best-effort — keep stale data visible on transient errors
    } finally {
      this.loading = false;
      if (this.expanded && !this.isDestroying) {
        this._pollTimer = later(
          this,
          this._fetchLiveData,
          LIVE_POLL_INTERVAL_MS
        );
      }
    }
  }

  _stopPolling() {
    if (this._pollTimer) {
      cancel(this._pollTimer);
      this._pollTimer = null;
    }
  }

  <template>
    <InsightsExploreSection
      @expanded={{this.expanded}}
      @summary={{i18n "discourse_insights.live.summary"}}
      @onToggle={{this.toggle}}
      @class="insights-live"
      @bodyClass="insights-live__body"
    >
        <:title>
          <span class="insights-live__pulse"></span>
          {{i18n "discourse_insights.live.title"}}
        </:title>
        <:body>
          {{#if this.loading}}
            <div class="spinner small"></div>
          {{else unless this.liveData}}
            <div class="insights-live__empty">{{i18n
                "discourse_insights.live.no_activity"
              }}</div>
          {{else}}
            <div class="insights-card">
              <div class="insights-live__stats">
                <div class="insights-live__stat">
                  <span
                    class="insights-live__stat-value"
                  >{{this.liveData.active_users}}</span>
                  <span
                    class="insights-live__stat-label"
                  >{{this.activeLabel}}</span>
                </div>
                <div class="insights-live__stat">
                  <span
                    class="insights-live__stat-value"
                  >{{this.liveData.composing.total}}</span>
                  <span
                    class="insights-live__stat-label"
                  >{{this.composingLabel}}</span>
                  {{#if this.composingDetail}}
                    <span
                      class="insights-live__stat-detail"
                    >{{this.composingDetail}}</span>
                  {{/if}}
                </div>
              </div>

              {{#if this.hotCategories.length}}
                <div class="insights-live__section">
                  <div class="insights-live__section-title">{{i18n
                      "discourse_insights.live.hot_categories"
                    }}</div>
                  <div class="insights-live__hot-cats">
                    {{#each this.hotCategories as |cat|}}
                      <span class="insights-live__hot-cat">
                        <span
                          class="insights-cat-dot"
                          style={{cat.dotStyle}}
                        ></span>
                        {{cat.name}}
                        <span
                          class="insights-live__hot-cat-count"
                        >{{cat.recent_posts}}</span>
                      </span>
                    {{/each}}
                    <span class="insights-live__hot-cats-suffix">{{i18n
                        "discourse_insights.live.hot_categories_suffix"
                        window=this.categoriesWindow
                      }}</span>
                  </div>
                </div>
              {{/if}}

              {{#if this.hotChatChannels.length}}
                <div class="insights-live__section">
                  <div class="insights-live__section-title">{{i18n
                      "discourse_insights.live.hot_chat_channels"
                    }}</div>
                  <div class="insights-live__hot-cats">
                    {{#each this.hotChatChannels as |ch|}}
                      <span class="insights-live__hot-cat">
                        <span
                          class="insights-cat-dot"
                          style={{ch.dotStyle}}
                        ></span>
                        <a href={{ch.url}}>{{ch.name}}</a>
                        <span
                          class="insights-live__hot-cat-count"
                        >{{ch.recent_messages}}</span>
                      </span>
                    {{/each}}
                    <span class="insights-live__hot-cats-suffix">{{i18n
                        "discourse_insights.live.hot_chat_suffix"
                        window=this.chatWindow
                      }}</span>
                  </div>
                </div>
              {{/if}}

              <div class="insights-live__section">
                <div class="insights-live__section-title">{{i18n
                    "discourse_insights.live.activity"
                  }}</div>
                {{#if this.stream.length}}
                  <ul class="insights-live__stream">
                    {{#each this.stream as |item|}}
                      <li class="insights-live__stream-item">
                        <span
                          class="insights-live__stream-type insights-live__stream-type--{{item.dotType}}"
                        ></span>
                        <span class="insights-live__stream-text">
                          {{#if (eq item.type "topic_activity")}}
                            <a href={{item.url}}>{{item.topic_title}}</a>
                            {{#if item.countsText}}
                              <span
                                class="insights-live__stream-counts"
                              >{{item.countsText}}</span>
                            {{/if}}
                          {{else if item.url}}
                            <a href={{item.url}}>{{item.text}}</a>
                          {{else}}
                            {{item.text}}
                          {{/if}}
                        </span>
                        <span
                          class="insights-live__stream-time"
                        >{{item.relativeTime}}</span>
                      </li>
                    {{/each}}
                  </ul>
                {{else}}
                  <div class="insights-live__empty">{{i18n
                      "discourse_insights.live.no_activity"
                    }}</div>
                {{/if}}
              </div>
            </div>

            <div class="insights-upsell">
              <div class="insights-upsell__text">
                <span class="insights-upsell__title">{{i18n
                    "discourse_insights.live.anon_upsell_title"
                  }}</span>
                <span class="insights-upsell__desc">{{i18n
                    "discourse_insights.live.anon_upsell_desc"
                  }}</span>
              </div>
              <a
                href="https://discourse.org/enterprise"
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-primary insights-upsell__cta"
              >{{i18n "discourse_insights.explore.geo_upsell_cta"}}</a>
            </div>
          {{/if}}
        </:body>
      </InsightsExploreSection>
  </template>
}
