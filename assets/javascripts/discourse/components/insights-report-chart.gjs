import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/components/d-button";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import getURL from "discourse/lib/get-url";
import loadChartJS from "discourse/lib/load-chart-js";
import { i18n } from "discourse-i18n";

const SERIES_COLORS = [
  "#1EB8D1",
  "#9BC53D",
  "#721D8D",
  "#E84A5F",
  "#8A6916",
  "#FFCD56",
];

function themeColor(name) {
  return getComputedStyle(document.body).getPropertyValue(name);
}

function looksLikeDate(value) {
  if (!value || typeof value !== "string") {
    return false;
  }
  return /^\d{4}-\d{2}-\d{2}/.test(value);
}

function isNumericColumn(rows, colIndex) {
  for (const row of rows) {
    const val = row[colIndex];
    if (val !== null && val !== undefined && val !== "") {
      return Number.isFinite(Number(val));
    }
  }
  return false;
}

export default class InsightsReportChart extends Component {
  @tracked loading = true;
  @tracked error = false;
  @tracked columns = null;
  @tracked rows = null;
  @tracked queryParams = null;
  @tracked showTable = false;
  @tracked rerunning = false;
  @tracked editableParams = new Map();
  chart = null;
  _canvas = null;

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
      this.queryParams = result.params || [];
      this.editableParams = new Map(
        this.queryParams.map((p) => [p.identifier, p.value ?? p.default])
      );
      this.error = false;
    } catch {
      this.error = true;
    } finally {
      this.loading = false;
    }
  }

  get numericColumnIndices() {
    if (!this.rows?.length || !this.columns?.length) {
      return [];
    }
    const indices = [];
    for (let i = 1; i < this.columns.length; i++) {
      if (isNumericColumn(this.rows, i)) {
        indices.push(i);
      }
    }
    return indices;
  }

  get isMultiSeries() {
    return this.numericColumnIndices.length > 1;
  }

  get hasDates() {
    return this.rows?.length > 0 && looksLikeDate(this.rows[0][0]);
  }

  get chartType() {
    if (!this.rows?.length || !this.columns?.length) {
      return "bar";
    }
    if (this.isMultiSeries) {
      return "bar";
    }
    return this.hasDates ? "line" : "bar";
  }

  buildChartConfig() {
    const labels = this.rows.map((r) => r[0]);
    const gridColor = themeColor("--primary-low").trim();
    const labelColor = themeColor("--primary-medium").trim();

    if (this.isMultiSeries) {
      return this._buildMultiSeriesConfig(labels, gridColor, labelColor);
    }

    return this._buildSingleSeriesConfig(labels, gridColor, labelColor);
  }

  _buildSingleSeriesConfig(labels, gridColor, labelColor) {
    const values = this.rows.map((r) => Number(r[1]));
    const isLine = this.chartType === "line";
    const primaryColor = themeColor("--tertiary").trim();

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

  _buildMultiSeriesConfig(labels, gridColor, labelColor) {
    const indices = this.numericColumnIndices;
    const useDates = this.hasDates;

    const datasets = indices.map((colIdx, i) => {
      const color = SERIES_COLORS[i % SERIES_COLORS.length];
      const ds = {
        label: this.columns[colIdx],
        data: this.rows.map((r) => Number(r[colIdx])),
        backgroundColor: color,
        borderColor: color,
        borderWidth: 1,
      };

      if (useDates) {
        ds.stack = "insights-stack";
      }

      return ds;
    });

    const scales = {
      x: {
        ticks: { color: labelColor, maxTicksLimit: 8 },
        grid: { display: false },
      },
      y: {
        ticks: { color: labelColor },
        grid: { color: gridColor },
        beginAtZero: true,
      },
    };

    if (useDates) {
      scales.x.stacked = true;
      scales.y.stacked = true;
    }

    return {
      type: "bar",
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: true, position: "bottom" },
          tooltip: {
            mode: "index",
            intersect: false,
            callbacks: {
              beforeFooter(items) {
                const total = items.reduce(
                  (sum, item) => sum + (item.parsed.y || 0),
                  0
                );
                return `Total: ${total.toLocaleString()}`;
              },
            },
          },
        },
        scales,
      },
    };
  }

  @action
  async initChart(canvas) {
    this._canvas = canvas;
    if (!this.rows?.length || this.numericColumnIndices.length === 0) {
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

  get hasParams() {
    return this.queryParams?.length > 0;
  }

  get editableParamFields() {
    if (!this.queryParams) {
      return [];
    }
    const editableTypes = ["date", "int", "bigint", "double", "string", "boolean"];
    return this.queryParams.map((p) => ({
      identifier: p.identifier,
      type: p.type,
      value: this.editableParams.get(p.identifier) ?? p.value ?? p.default,
      editable: editableTypes.includes(p.type),
      inputType: this._inputTypeFor(p.type),
      inputStep: this._inputStepFor(p.type),
      isCheckbox: p.type === "boolean",
    }));
  }

  _inputTypeFor(paramType) {
    switch (paramType) {
      case "date":
        return "date";
      case "int":
      case "bigint":
      case "double":
        return "number";
      case "boolean":
        return "checkbox";
      default:
        return "text";
    }
  }

  _inputStepFor(paramType) {
    if (paramType === "double") {
      return "any";
    }
    if (paramType === "int" || paramType === "bigint") {
      return "1";
    }
    return undefined;
  }

  @action
  updateParam(identifier, event) {
    const val =
      event.target.type === "checkbox"
        ? String(event.target.checked)
        : event.target.value;
    this.editableParams = new Map(this.editableParams);
    this.editableParams.set(identifier, val);
  }

  @action
  async rerun() {
    this.rerunning = true;
    try {
      const data = {};
      for (const [key, val] of this.editableParams) {
        if (val !== null && val !== undefined && val !== "") {
          data[key] = val;
        }
      }
      const result = await ajax(
        `/insights/reports/${this.args.report.id}/run.json`,
        { data }
      );
      this.columns = result.columns;
      this.rows = result.rows;
      this.queryParams = result.params || [];
      this.editableParams = new Map(
        this.queryParams.map((p) => [p.identifier, p.value ?? p.default])
      );
      this.error = false;

      if (
        this._canvas &&
        this.rows?.length &&
        this.numericColumnIndices.length > 0
      ) {
        const Chart = await loadChartJS();
        this.chart?.destroy();
        this.chart = new Chart(
          this._canvas.getContext("2d"),
          this.buildChartConfig()
        );
      }
    } catch {
      this.error = true;
    } finally {
      this.rerunning = false;
    }
  }

  get tableWrapId() {
    return `insights-table-${this.args.report.id}`;
  }

  @action
  toggleTable() {
    this.showTable = !this.showTable;
  }

  @action
  removeReport() {
    this.args.onRemove?.(this.args.report.id);
  }

  <template>
    <div class="insights-report-chart">
      <div class="insights-report-chart__header">
        <div class="insights-report-chart__title-wrap">
          {{#if @report.insights}}<span
              class="insights-sparkle-badge"
              title={{i18n "discourse_insights.reports.insights_query_tooltip"}}
            >✦</span>{{/if}}
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
        <div class="insights-report-chart__data-section">
          <div class="insights-report-chart__table-toggle">
            <button
              type="button"
              class="btn-transparent insights-report-chart__toggle-btn"
              aria-expanded={{if this.showTable "true" "false"}}
              aria-controls={{this.tableWrapId}}
              {{on "click" this.toggleTable}}
            >
              {{icon (if this.showTable "chevron-down" "chevron-right")}}
              {{if this.showTable (i18n "discourse_insights.reports.hide_data") (i18n "discourse_insights.reports.show_data")}}
            </button>
            <a
              href={{this.queryUrl}}
              class="insights-report-chart__de-link"
              aria-label={{i18n "discourse_insights.reports.open_in_data_explorer"}}
            >
              {{icon "external-link-alt"}}
            </a>
          </div>
          <div
            id={{this.tableWrapId}}
            class={{if this.showTable "insights-report-chart__table-wrap insights-report-chart__table-wrap--open" "insights-report-chart__table-wrap"}}
          >
            {{#if this.showTable}}
              {{#if this.hasParams}}
                <div class="insights-report-chart__params">
                  {{#each this.editableParamFields as |p|}}
                    {{#if p.editable}}
                      <label class="insights-report-chart__param-field">
                        <span class="insights-report-chart__param-label">{{p.identifier}}</span>
                        {{#if p.isCheckbox}}
                          <input
                            type="checkbox"
                            checked={{eq p.value "true"}}
                            class="insights-report-chart__param-input"
                            {{on "change" (fn this.updateParam p.identifier)}}
                          />
                        {{else}}
                          <input
                            type={{p.inputType}}
                            step={{p.inputStep}}
                            value={{p.value}}
                            class="insights-report-chart__param-input"
                            {{on "change" (fn this.updateParam p.identifier)}}
                          />
                        {{/if}}
                      </label>
                    {{else}}
                      <span class="insights-report-chart__param-chip">{{p.identifier}}: {{p.value}}</span>
                    {{/if}}
                  {{/each}}
                  <DButton
                    class="btn-transparent btn-small insights-report-chart__run-btn"
                    @action={{this.rerun}}
                    @icon="play"
                    @title="discourse_insights.reports.run"
                    @disabled={{this.rerunning}}
                  />
                </div>
              {{/if}}
              <div class="insights-report-chart__table-scroll">
                <table class="insights-report-chart__table">
                  <thead>
                    <tr>
                      {{#each this.columns as |col|}}
                        <th>{{col}}</th>
                      {{/each}}
                    </tr>
                  </thead>
                  <tbody>
                    {{#each this.rows as |row|}}
                      <tr>
                        {{#each row as |cell|}}
                          <td>{{cell}}</td>
                        {{/each}}
                      </tr>
                    {{/each}}
                  </tbody>
                </table>
              </div>
            {{/if}}
          </div>
        </div>
      {{else}}
        <div class="insights-report-chart__empty">
          {{i18n "discourse_insights.reports.no_data"}}
        </div>
      {{/if}}
    </div>
  </template>
}
