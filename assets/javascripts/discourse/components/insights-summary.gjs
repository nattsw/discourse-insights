import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { cancel, later } from "@ember/runloop";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import CookText from "discourse/components/cook-text";
import DButton from "discourse/components/d-button";
import number from "discourse/helpers/number";
import { ajax } from "discourse/lib/ajax";
import { bind } from "discourse/lib/decorators";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

const AI_TIMEOUT_MS = 30000;

const METRIC_KEYS = [
  "visitors",
  "page_views",
  "new_members",
  "contributors",
  "posts",
  "likes",
  "solved",
  "response_rate",
];

function formatTrendText(pct, isPercentage) {
  if (isPercentage) {
    if (pct > 0) {
      return `↑ ${pct}pts`;
    }
    if (pct < 0) {
      return `↓ ${Math.abs(pct)}pts`;
    }
    return "— flat";
  }
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

export default class InsightsSummary extends Component {
  @service messageBus;

  @tracked expandedMetric = null;
  @tracked expandedQuestion = null;

  // ai state
  @tracked aiSummary = "";
  @tracked aiSummaryLoading = false;
  @tracked aiSummaryDone = false;
  @tracked aiAnswer = "";
  @tracked aiAnswerLoading = false;
  @tracked aiAnswerDone = false;
  @tracked aiAnswerType = null;
  @tracked aiSummaryError = false;
  @tracked aiAnswerError = false;
  @tracked customQuestion = "";

  _aiSummaryTimer = null;
  _aiAnswerTimer = null;
  _aiCache = new Map();

  get aiAvailable() {
    return !!this.args.data?.ai_available;
  }

  get metrics() {
    if (!this.args.data?.metrics) {
      return [];
    }
    return METRIC_KEYS.map((key) => {
      const m = this.args.data.metrics[key];
      if (!m || (key === "solved" && m.available === false)) {
        return null;
      }
      return {
        key,
        label: i18n(`discourse_insights.metrics.${key}`),
        current: m.current,
        isPercentage: !!m.is_percentage,
        trendText: formatTrendText(m.trend_pct, m.is_percentage),
        trendClass: trendCssClass(m.trend_pct),
      };
    }).filter(Boolean);
  }

  get isGrowing() {
    return (this.args.data?.metrics?.visitors?.trend_pct ?? 0) > 5;
  }

  get isDeclining() {
    return (this.args.data?.metrics?.visitors?.trend_pct ?? 0) < -5;
  }

  get absVisitorsTrend() {
    return Math.abs(this.args.data?.metrics?.visitors?.trend_pct ?? 0);
  }

  get membersCount() {
    return this.args.data?.metrics?.new_members?.current ?? 0;
  }

  get membersTrend() {
    return this.args.data?.metrics?.new_members?.trend_pct ?? 0;
  }

  get visitorsCount() {
    return this.args.data?.metrics?.visitors?.current ?? 0;
  }

  get topReferrer() {
    return this.args.data?.traffic_sources?.[0] ?? null;
  }

  get topTopic() {
    return this.args.data?.top_topics?.[0] ?? null;
  }

  get comparisonLabel() {
    if (!this.args.data?.period) {
      return "";
    }
    const start = moment(this.args.data.period.comparison_start);
    const end = moment(this.args.data.period.comparison_end);
    return `${start.format("MMM D")}–${end.format("MMM D, YYYY")}`;
  }

  get expandedMetricData() {
    if (!this.expandedMetric || !this.args.data?.metrics) {
      return null;
    }
    return this.args.data.metrics[this.expandedMetric];
  }

  get expandedMetricTitle() {
    if (!this.expandedMetric) {
      return "";
    }
    return i18n(`discourse_insights.metrics.${this.expandedMetric}`);
  }

  get sparklinePath() {
    const daily = this.expandedMetricData?.daily;
    if (!daily?.length) {
      return null;
    }
    const values = daily.map((d) => d.value);
    const max = Math.max(...values, 1);
    const w = 300;
    const h = 60;
    const pad = 2;
    const stepX = values.length > 1 ? w / (values.length - 1) : 0;

    const points = values.map((v, idx) => {
      const x = idx * stepX;
      const y = pad + (h - 2 * pad) * (1 - v / max);
      return `${x},${y}`;
    });

    return htmlSafe(`M${points.join(" L")}`);
  }

  get sparklineFillPath() {
    const daily = this.expandedMetricData?.daily;
    if (!daily?.length) {
      return null;
    }
    const values = daily.map((d) => d.value);
    const max = Math.max(...values, 1);
    const w = 300;
    const h = 60;
    const pad = 2;
    const stepX = values.length > 1 ? w / (values.length - 1) : 0;

    const points = values.map((v, idx) => {
      const x = idx * stepX;
      const y = pad + (h - 2 * pad) * (1 - v / max);
      return `${x},${y}`;
    });

    return htmlSafe(`M0,${h} L${points.join(" L")} L${w},${h} Z`);
  }

  get decliningCategories() {
    return (this.args.data?.categories ?? []).filter((c) => c.trend_pct < -3);
  }

  get contentGaps() {
    return (this.args.data?.search_terms ?? []).filter((s) => s.content_gap);
  }

  get questions() {
    return [
      {
        key: "categories",
        label: i18n("discourse_insights.questions.categories"),
      },
      {
        key: "content",
        label: i18n("discourse_insights.questions.content"),
      },
      {
        key: "deflection",
        label: i18n("discourse_insights.questions.deflection"),
      },
      {
        key: "stakeholder",
        label: i18n("discourse_insights.questions.stakeholder"),
      },
    ];
  }

  get questionAnswer() {
    if (!this.expandedQuestion || !this.args.data) {
      return null;
    }

    switch (this.expandedQuestion) {
      case "categories": {
        const declining = this.decliningCategories;
        if (declining.length === 0) {
          return i18n("discourse_insights.answers.categories_healthy");
        }
        return i18n("discourse_insights.answers.categories_declining", {
          names: declining.map((c) => c.name).join(", "),
        });
      }
      case "content": {
        const gaps = this.contentGaps;
        if (gaps.length === 0) {
          return i18n("discourse_insights.answers.content_no_gaps");
        }
        return i18n("discourse_insights.answers.content_gaps", {
          terms: gaps.map((g) => `"${g.term}"`).join(", "),
        });
      }
      case "deflection": {
        const solved = this.args.data.metrics?.solved;
        if (!solved || solved.available === false) {
          return i18n("discourse_insights.answers.deflection_unavailable");
        }
        return i18n("discourse_insights.answers.deflection", {
          solved: solved.current,
          solve_rate: solved.solve_rate ?? 0,
          response_rate: this.args.data.metrics?.response_rate?.current ?? 0,
          avg_hours:
            this.args.data.metrics?.response_rate?.avg_first_response_hours ??
            0,
        });
      }
      case "stakeholder":
        return i18n("discourse_insights.answers.stakeholder", {
          visitors: this.args.data.metrics?.visitors?.current ?? 0,
          visitors_trend: this.args.data.metrics?.visitors?.trend_pct ?? 0,
          members: this.args.data.metrics?.new_members?.current ?? 0,
          members_trend: this.args.data.metrics?.new_members?.trend_pct ?? 0,
          posts: this.args.data.metrics?.posts?.current ?? 0,
          response_rate: this.args.data.metrics?.response_rate?.current ?? 0,
        });
      default:
        return null;
    }
  }

  get _periodKey() {
    const p = this.args.data?.period;
    if (!p) {
      return null;
    }
    return `${p.start_date}_${p.end_date}`;
  }

  get _periodParams() {
    const p = this.args.data?.period;
    if (!p) {
      return {};
    }
    if (p.period_id) {
      return { period: p.period_id };
    }
    return { start_date: p.start_date, end_date: p.end_date };
  }

  // ai lifecycle

  @bind
  subscribeAi() {
    this.messageBus.subscribe("/insights/ai/stream", this._onAiStream);
    this.triggerAiSummary();
  }

  @bind
  onDataChanged() {
    this._resetAiState();
    this.triggerAiSummary();
  }

  @bind
  unsubscribeAi() {
    this.messageBus.unsubscribe("/insights/ai/stream", this._onAiStream);
    cancel(this._aiSummaryTimer);
    cancel(this._aiAnswerTimer);
  }

  @bind
  _onAiStream(update) {
    const periodKey = this._periodKey;
    if (update.type === "summary") {
      this.aiSummary = update.text;
      this.aiSummaryLoading = false;
      if (update.done) {
        this.aiSummaryDone = true;
        cancel(this._aiSummaryTimer);
        this._aiCache.set(`summary_${periodKey}`, update.text);
      }
    } else {
      if (update.type !== this.aiAnswerType) {
        return;
      }
      this.aiAnswer = update.text;
      this.aiAnswerLoading = false;
      if (update.done) {
        this.aiAnswerDone = true;
        cancel(this._aiAnswerTimer);
        if (update.type !== "custom") {
          this._aiCache.set(`${update.type}_${periodKey}`, update.text);
        }
      }
    }
  }

  triggerAiSummary() {
    if (!this.aiAvailable) {
      return;
    }

    const cached = this._aiCache.get(`summary_${this._periodKey}`);
    if (cached) {
      this.aiSummary = cached;
      this.aiSummaryDone = true;
      this.aiSummaryLoading = false;
      return;
    }

    this.aiSummary = "";
    this.aiSummaryLoading = true;
    this.aiSummaryDone = false;
    this.aiSummaryError = false;

    this._aiSummaryTimer = later(
      this,
      () => {
        if (!this.aiSummaryDone && this.aiSummary.length === 0) {
          this.aiSummaryLoading = false;
          this.aiSummaryError = true;
        }
      },
      AI_TIMEOUT_MS
    );

    ajax("/insights/ai/generate.json", {
      type: "POST",
      data: { type: "summary", ...this._periodParams },
    })
      .then((result) => {
        if (result.text) {
          this.aiSummary = result.text;
          this.aiSummaryLoading = false;
          this.aiSummaryDone = true;
          cancel(this._aiSummaryTimer);
          this._aiCache.set(`summary_${this._periodKey}`, result.text);
        }
      })
      .catch(() => {
        this.aiSummaryLoading = false;
      });
  }

  triggerAiAnswer(type, question) {
    if (!this.aiAvailable) {
      return;
    }

    if (type !== "custom") {
      const cached = this._aiCache.get(`${type}_${this._periodKey}`);
      if (cached) {
        this.aiAnswer = cached;
        this.aiAnswerDone = true;
        this.aiAnswerLoading = false;
        this.aiAnswerType = type;
        return;
      }
    }

    this.aiAnswer = "";
    this.aiAnswerLoading = true;
    this.aiAnswerDone = false;
    this.aiAnswerError = false;
    this.aiAnswerType = type;

    this._aiAnswerTimer = later(
      this,
      () => {
        if (!this.aiAnswerDone && this.aiAnswer.length === 0) {
          this.aiAnswerLoading = false;
          this.aiAnswerError = true;
        }
      },
      AI_TIMEOUT_MS
    );

    const data = { type, ...this._periodParams };
    if (type === "custom") {
      data.question = question;
    }

    ajax("/insights/ai/generate.json", {
      type: "POST",
      data,
    })
      .then((result) => {
        if (result.text) {
          this.aiAnswer = result.text;
          this.aiAnswerLoading = false;
          this.aiAnswerDone = true;
          this.aiAnswerType = type;
          cancel(this._aiAnswerTimer);
          if (type !== "custom") {
            this._aiCache.set(`${type}_${this._periodKey}`, result.text);
          }
        }
      })
      .catch(() => {
        this.aiAnswerLoading = false;
      });
  }

  _resetAiState() {
    this.aiSummary = "";
    this.aiSummaryDone = false;
    this.aiSummaryError = false;
    this.aiAnswer = "";
    this.aiAnswerDone = false;
    this.aiAnswerError = false;
  }

  // ui actions

  @action
  toggleMetric(key) {
    this.expandedMetric = this.expandedMetric === key ? null : key;
  }

  @action
  closeMetric() {
    this.expandedMetric = null;
  }

  @action
  toggleQuestion(key) {
    if (this.expandedQuestion === key) {
      this.expandedQuestion = null;
      return;
    }
    this.expandedQuestion = key;
    this.triggerAiAnswer(key);
  }

  @action
  submitCustomQuestion(event) {
    event.preventDefault();
    const q = this.customQuestion?.trim();
    if (!q || !this.aiAvailable) {
      return;
    }
    this.expandedQuestion = "custom";
    this.triggerAiAnswer("custom", q);
  }

  @action
  updateCustomQuestion(event) {
    this.customQuestion = event.target.value;
  }

  <template>
    <div
      class="insights-summary"
      {{didInsert this.subscribeAi}}
      {{didUpdate this.onDataChanged @data}}
      {{willDestroy this.unsubscribeAi}}
    >
      <div class="insights-summary__header">
        <span class="insights-summary__icon">✦</span>
        <span class="insights-summary__title">{{i18n
            "discourse_insights.insights.title"
          }}</span>
      </div>

      {{#if this.aiSummaryLoading}}
        <div class="insights-ai-loading">
          <span class="insights-ai-loading__dots">
            <span></span><span></span><span></span>
          </span>
        </div>
      {{else if this.aiSummaryError}}
        <p class="insights-ai-error">{{i18n
            "discourse_insights.ai_timeout"
          }}</p>
      {{else if this.aiSummary}}
        <div class="insights-ai-narrative">
          <CookText @rawText={{this.aiSummary}} />
        </div>
      {{else}}
        <p class="insights-summary__narrative">
          {{#if this.isGrowing}}
            {{i18n
              "discourse_insights.insights.growing"
              visitors_trend=this.absVisitorsTrend
              members_count=this.membersCount
              members_trend=this.membersTrend
            }}
          {{else if this.isDeclining}}
            {{i18n
              "discourse_insights.insights.declining"
              visitors_trend=this.absVisitorsTrend
            }}
          {{else}}
            {{i18n
              "discourse_insights.insights.steady"
              visitors=this.visitorsCount
              members_count=this.membersCount
            }}
          {{/if}}
          {{#if this.topReferrer}}

            {{i18n
              "discourse_insights.insights.top_referrer"
              domain=this.topReferrer.domain
              clicks=this.topReferrer.clicks
            }}
          {{/if}}
          {{#if this.topTopic}}

            {{i18n
              "discourse_insights.insights.top_topic"
              title=this.topTopic.title
              views=this.topTopic.views
            }}
          {{/if}}
        </p>
      {{/if}}

      <div class="insights-metrics">
        {{#each this.metrics as |metric|}}
          <button
            type="button"
            class="insights-metric
              {{if
                (eq this.expandedMetric metric.key)
                'insights-metric--active'
              }}"
            {{on "click" (fn this.toggleMetric metric.key)}}
          >
            <span class="insights-metric__label">{{metric.label}}</span>
            <span class="insights-metric__value">
              {{#if metric.isPercentage}}
                {{metric.current}}%
              {{else}}
                {{number metric.current}}
              {{/if}}
            </span>
            <span
              class="insights-metric__trend {{metric.trendClass}}"
            >{{metric.trendText}}</span>
          </button>
        {{/each}}
        {{#if this.comparisonLabel}}
          <span class="insights-metrics__compare">{{i18n
              "discourse_insights.compare_to"
              dates=this.comparisonLabel
            }}</span>
        {{/if}}
      </div>

      {{#if this.expandedMetricData}}
        <div class="insights-detail-panel">
          <div class="insights-detail-panel__header">
            <span
              class="insights-detail-panel__title"
            >{{this.expandedMetricTitle}}</span>
            <DButton
              class="btn-transparent insights-detail-panel__close"
              @action={{this.closeMetric}}
              @icon="xmark"
            />
          </div>
          <div class="insights-detail-panel__body">
            {{#if this.sparklinePath}}
              <svg
                class="insights-sparkline"
                viewBox="0 0 300 60"
                preserveAspectRatio="none"
              >
                <path
                  class="insights-sparkline__fill"
                  d={{this.sparklineFillPath}}
                />
                <path
                  class="insights-sparkline__line"
                  d={{this.sparklinePath}}
                />
              </svg>
            {{/if}}

            <div class="insights-detail-panel__stats">
              <span class="insights-detail-panel__stat">
                {{i18n "discourse_insights.detail.current"}}
                <strong>{{number this.expandedMetricData.current}}</strong>
              </span>
              <span class="insights-detail-panel__stat">
                {{i18n "discourse_insights.detail.previous"}}
                <strong>{{number this.expandedMetricData.previous}}</strong>
              </span>
              {{#if this.expandedMetricData.avg_per_day}}
                <span class="insights-detail-panel__stat">
                  {{i18n "discourse_insights.detail.avg_per_day"}}
                  <strong>{{number
                      this.expandedMetricData.avg_per_day
                    }}</strong>
                </span>
              {{/if}}
              {{#if this.expandedMetricData.like_to_post_ratio}}
                <span class="insights-detail-panel__stat">
                  {{i18n "discourse_insights.detail.like_ratio"}}
                  <strong
                  >{{this.expandedMetricData.like_to_post_ratio}}</strong>
                </span>
              {{/if}}
              {{#if this.expandedMetricData.avg_first_response_hours}}
                <span class="insights-detail-panel__stat">
                  {{i18n "discourse_insights.detail.avg_response_time"}}
                  <strong
                  >{{this.expandedMetricData.avg_first_response_hours}}h</strong>
                </span>
              {{/if}}
              {{#if this.expandedMetricData.unanswered_count}}
                <span class="insights-detail-panel__stat">
                  {{i18n "discourse_insights.detail.unanswered"}}
                  <strong>{{this.expandedMetricData.unanswered_count}}</strong>
                </span>
              {{/if}}
              {{#if this.expandedMetricData.solve_rate}}
                <span class="insights-detail-panel__stat">
                  {{i18n "discourse_insights.detail.solve_rate"}}
                  <strong>{{this.expandedMetricData.solve_rate}}%</strong>
                </span>
              {{/if}}
            </div>

            {{#if (eq this.expandedMetric "contributors")}}
              <div class="insights-detail-panel__extra">
                <span>{{i18n "discourse_insights.detail.dau"}}
                  {{@data.dau_wau_mau.dau}}</span>
                <span>{{i18n "discourse_insights.detail.wau"}}
                  {{@data.dau_wau_mau.wau}}</span>
                <span>{{i18n "discourse_insights.detail.mau"}}
                  {{@data.dau_wau_mau.mau}}</span>
                <span>{{i18n "discourse_insights.detail.dau_mau"}}
                  {{@data.dau_wau_mau.dau_mau_ratio}}%</span>
              </div>
            {{/if}}

            {{#if (eq this.expandedMetric "posts")}}
              <div class="insights-detail-panel__extra">
                <span>{{i18n "discourse_insights.detail.new_topics"}}:
                  {{@data.posts_breakdown.topics}}</span>
                <span>{{i18n "discourse_insights.detail.replies"}}:
                  {{@data.posts_breakdown.replies}}</span>
              </div>
            {{/if}}
          </div>
        </div>
      {{/if}}

      <div class="insights-questions">
        {{#each this.questions as |q|}}
          <button
            type="button"
            class="insights-question-chip
              {{if
                (eq this.expandedQuestion q.key)
                'insights-question-chip--active'
              }}"
            {{on "click" (fn this.toggleQuestion q.key)}}
          >
            {{q.label}}
          </button>
        {{/each}}
      </div>

      {{#if this.aiAvailable}}
        <form class="insights-ask" {{on "submit" this.submitCustomQuestion}}>
          <input
            type="text"
            class="insights-ask__input"
            placeholder={{i18n
              "discourse_insights.questions.custom_placeholder"
            }}
            value={{this.customQuestion}}
            {{on "input" this.updateCustomQuestion}}
          />
        </form>
      {{/if}}

      {{#if this.expandedQuestion}}
        <div class="insights-answer">
          {{#if this.aiAnswerLoading}}
            <div class="insights-ai-loading">
              <span class="insights-ai-loading__dots">
                <span></span><span></span><span></span>
              </span>
            </div>
          {{else if this.aiAnswerError}}
            <p class="insights-ai-error">{{i18n
                "discourse_insights.ai_timeout"
              }}</p>
          {{else if this.aiAnswer}}
            <div class="insights-ai-answer">
              <CookText @rawText={{this.aiAnswer}} />
            </div>
          {{else if this.questionAnswer}}
            <div class="insights-answer__text">{{this.questionAnswer}}</div>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
