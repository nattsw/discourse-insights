import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import getURL from "discourse/lib/get-url";
import loadChartJS from "discourse/lib/load-chart-js";
import { i18n } from "discourse-i18n";

function themeColor(name) {
  return getComputedStyle(document.body).getPropertyValue(name);
}

function looksLikeDate(value) {
  if (!value || typeof value !== "string") {
    return false;
  }
  return /^\d{4}-\d{2}-\d{2}/.test(value);
}

export default class InsightsReportChart extends Component {
  @tracked loading = true;
  @tracked error = false;
  @tracked columns = null;
  @tracked rows = null;
  chart = null;

  constructor() {
    super(...arguments);
    this.fetchAndRender();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.chart?.destroy();
  }

  async fetchAndRender() {
    try {
      const data = {};
      if (this.args.startDate) {
        data.start_date = this.args.startDate;
      }
      if (this.args.endDate) {
        data.end_date = this.args.endDate;
      }
      const result = await ajax(
        `/insights/reports/${this.args.report.id}/run.json`,
        { data }
      );
      this.columns = result.columns;
      this.rows = result.rows;
      this.error = false;
    } catch {
      this.error = true;
    } finally {
      this.loading = false;
    }
  }

  get chartType() {
    if (!this.rows?.length || !this.columns?.length) {
      return "bar";
    }
    return looksLikeDate(this.rows[0][0]) ? "line" : "bar";
  }

  buildChartConfig() {
    const labels = this.rows.map((r) => r[0]);
    const values = this.rows.map((r) => Number(r[1]));
    const isLine = this.chartType === "line";

    const primaryColor = themeColor("--tertiary").trim();
    const gridColor = themeColor("--primary-low").trim();
    const labelColor = themeColor("--primary-medium").trim();

    const dataset = {
      label: this.columns[1],
      data: values,
      backgroundColor: isLine ? "transparent" : primaryColor,
      borderColor: primaryColor,
      borderWidth: isLine ? 2 : 0,
      pointRadius: isLine ? 2 : 0,
      pointHoverRadius: isLine ? 4 : 0,
      tension: 0.3,
    };

    return {
      type: this.chartType,
      data: { labels, datasets: [dataset] },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              label: (ctx) => `${ctx.dataset.label}: ${ctx.formattedValue}`,
            },
          },
        },
        scales: {
          x: {
            ticks: { color: labelColor, maxTicksLimit: 8 },
            grid: { display: false },
          },
          y: {
            ticks: { color: labelColor },
            grid: { color: gridColor },
            beginAtZero: true,
          },
        },
      },
    };
  }

  @action
  async initChart(canvas) {
    if (!this.rows?.length || this.columns?.length < 2) {
      return;
    }

    const Chart = await loadChartJS();
    if (this.chart) {
      this.chart.destroy();
    }
    this.chart = new Chart(canvas.getContext("2d"), this.buildChartConfig());
  }

  get queryUrl() {
    return getURL(
      `/admin/plugins/discourse-data-explorer/queries/${this.args.report.id}`
    );
  }

  @action
  removeReport() {
    this.args.onRemove?.(this.args.report.id);
  }

  <template>
    <div class="insights-report-chart">
      <div class="insights-report-chart__header">
        <div class="insights-report-chart__title-wrap">
          {{#if @report.insights}}<span class="insights-sparkle-badge" title={{i18n "discourse_insights.reports.insights_query_tooltip"}}>✦</span>{{/if}}
          <a
            href={{this.queryUrl}}
            class="insights-report-chart__title"
          >{{@report.name}}</a>
        </div>
        <DButton
          class="btn-transparent btn-small insights-report-chart__remove"
          @action={{this.removeReport}}
          @icon="xmark"
          @title="discourse_insights.reports.remove_tooltip"
        />
      </div>
      {{#if this.loading}}
        <div class="insights-report-chart__loading">
          <div class="spinner small"></div>
        </div>
      {{else if this.error}}
        <div class="insights-report-chart__error">
          {{i18n "discourse_insights.reports.chart_error"}}
        </div>
      {{else if this.rows.length}}
        <div class="insights-report-chart__canvas-wrap">
          <canvas {{didInsert this.initChart}}></canvas>
        </div>
      {{else}}
        <div class="insights-report-chart__empty">
          {{i18n "discourse_insights.reports.no_data"}}
        </div>
      {{/if}}
    </div>
  </template>
}
