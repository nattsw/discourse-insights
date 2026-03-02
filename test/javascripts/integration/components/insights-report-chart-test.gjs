import { click, fillIn, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import InsightsReportChart, { clearReportCache } from "../../discourse/components/insights-report-chart";

function mockRun(reportId, responseData) {
  pretender.get(`/insights/reports/${reportId}/run.json`, () =>
    response(responseData)
  );
}

module(
  "Discourse Insights | Integration | Component | insights-report-chart",
  function (hooks) {
    setupRenderingTest(hooks);
    hooks.beforeEach(() => clearReportCache());

    test("renders line chart for 2-column date data", async function (assert) {
      mockRun(1, {
        columns: ["week", "count"],
        rows: [
          ["2025-01-06", 10],
          ["2025-01-13", 20],
          ["2025-01-20", 15],
        ],
        params: [],
      });

      const report = { id: 1, name: "Weekly Users", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__canvas-wrap canvas")
        .exists("renders a canvas for chart");
      assert
        .dom(".insights-report-chart__title")
        .hasText("Weekly Users");
    });

    test("renders bar chart for 2-column categorical data", async function (assert) {
      mockRun(2, {
        columns: ["category", "topics"],
        rows: [
          ["General", 50],
          ["Support", 30],
          ["Meta", 10],
        ],
        params: [],
      });

      const report = { id: 2, name: "Topics by Category", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__canvas-wrap canvas")
        .exists("renders a canvas for chart");
    });

    test("renders chart for 4-column date data (multi-series)", async function (assert) {
      mockRun(3, {
        columns: ["week", "logged_in", "anon", "crawlers"],
        rows: [
          ["2025-01-06", 100, 200, 50],
          ["2025-01-13", 120, 180, 60],
        ],
        params: [],
      });

      const report = { id: 3, name: "Traffic", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__canvas-wrap canvas")
        .exists("renders a canvas for multi-series chart");
    });

    test("renders chart for 3-column categorical data", async function (assert) {
      mockRun(4, {
        columns: ["category", "topics", "replies"],
        rows: [
          ["General", 50, 120],
          ["Support", 30, 90],
        ],
        params: [],
      });

      const report = { id: 4, name: "Category Activity", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__canvas-wrap canvas")
        .exists("renders a canvas for multi-series categorical chart");
    });

    test("data table toggle shows and hides table", async function (assert) {
      mockRun(5, {
        columns: ["week", "count"],
        rows: [
          ["2025-01-06", 10],
          ["2025-01-13", 20],
        ],
        params: [],
      });

      const report = { id: 5, name: "Test", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__table")
        .doesNotExist("table hidden by default");

      assert
        .dom(".insights-report-chart__toggle-btn")
        .hasAttribute("aria-expanded", "false");

      await click(".insights-report-chart__toggle-btn");

      assert
        .dom(".insights-report-chart__toggle-btn")
        .hasAttribute("aria-expanded", "true");

      assert
        .dom(".insights-report-chart__table")
        .exists("table visible after toggle");

      assert
        .dom(".insights-report-chart__table thead th:nth-child(1)")
        .hasText("week");
      assert
        .dom(".insights-report-chart__table thead th:nth-child(2)")
        .hasText("count");
      assert
        .dom(".insights-report-chart__table tbody tr:nth-child(1) td:nth-child(1)")
        .hasText("2025-01-06");
      assert
        .dom(".insights-report-chart__table tbody tr:nth-child(1) td:nth-child(2)")
        .hasText("10");

      await click(".insights-report-chart__toggle-btn");

      assert
        .dom(".insights-report-chart__table")
        .doesNotExist("table hidden after second toggle");
    });

    test("displays editable inputs for date params", async function (assert) {
      mockRun(6, {
        columns: ["d1", "d2"],
        rows: [["2026-01-01", "2026-02-01"]],
        params: [
          { identifier: "start_date", type: "date", default: "2025-01-01", value: "2026-01-01" },
          { identifier: "end_date", type: "date", default: "2025-12-31", value: "2026-02-01" },
        ],
      });

      const report = { id: 6, name: "Parameterized", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__params")
        .doesNotExist("params hidden before expanding");

      await click(".insights-report-chart__toggle-btn");

      assert
        .dom(".insights-report-chart__params")
        .exists("params section visible after expanding");

      const inputs = document.querySelectorAll(".insights-report-chart__param-input[type='date']");
      assert.strictEqual(inputs.length, 2, "renders 2 date inputs");
      assert.strictEqual(inputs[0].value, "2026-01-01", "first input has correct value");
      assert.strictEqual(inputs[1].value, "2026-02-01", "second input has correct value");

      const labels = document.querySelectorAll(".insights-report-chart__param-label");
      assert.true(labels[0].textContent.includes("start_date"), "first label shows start_date");

      assert
        .dom(".insights-report-chart__run-btn")
        .exists("run button is present");
    });

    test("does not display params section when no params", async function (assert) {
      mockRun(7, {
        columns: ["week", "count"],
        rows: [["2025-01-06", 10]],
        params: [],
      });

      const report = { id: 7, name: "No Params", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__params")
        .doesNotExist("no params section");
    });

    test("DE link is always visible and uses getURL path", async function (assert) {
      mockRun(8, {
        columns: ["week", "count"],
        rows: [["2025-01-06", 10]],
        params: [],
      });

      const report = { id: 8, name: "DE Link", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__de-link")
        .exists("DE link is visible even when table collapsed");
      assert
        .dom(".insights-report-chart__de-link")
        .hasAttribute("aria-label", "Open in Data Explorer");
      assert
        .dom(".insights-report-chart__de-link")
        .hasAttribute(
          "href",
          /\/admin\/plugins\/discourse-data-explorer\/queries\/8/
        );
    });

    test("non-numeric columns excluded from chart but present in table", async function (assert) {
      mockRun(9, {
        columns: ["name", "label", "count"],
        rows: [
          ["Alice", "admin", 42],
          ["Bob", "mod", 17],
        ],
        params: [],
      });

      const report = { id: 9, name: "Mixed Columns", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__canvas-wrap canvas")
        .exists("chart still renders");

      await click(".insights-report-chart__toggle-btn");

      assert
        .dom(".insights-report-chart__table thead th:nth-child(1)")
        .hasText("name", "non-numeric column in table");
      assert
        .dom(".insights-report-chart__table thead th:nth-child(2)")
        .hasText("label", "non-numeric column in table");
      assert
        .dom(".insights-report-chart__table thead th:nth-child(3)")
        .hasText("count", "numeric column in table");
    });

    test("shows no data message when rows are empty", async function (assert) {
      mockRun(10, {
        columns: ["week", "count"],
        rows: [],
        params: [],
      });

      const report = { id: 10, name: "Empty", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__empty")
        .exists("shows empty state");
      assert
        .dom(".insights-report-chart__data-section")
        .doesNotExist("no data section for empty results");
    });

    test("shows error state on fetch failure", async function (assert) {
      pretender.get("/insights/reports/11/run.json", () => [500, {}, ""]);

      const report = { id: 11, name: "Broken", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-report-chart__error")
        .exists("shows error state");
    });

    test("shows sparkle badge for insights queries", async function (assert) {
      mockRun(12, {
        columns: ["week", "count"],
        rows: [["2025-01-06", 10]],
        params: [],
      });

      const report = { id: 12, name: "Seeded", insights: true };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert
        .dom(".insights-sparkle-badge")
        .exists("sparkle badge rendered");
    });

    test("editable date params render as inputs", async function (assert) {
      mockRun(13, {
        columns: ["week", "count"],
        rows: [["2025-01-06", 10]],
        params: [
          { identifier: "start_date", type: "date", default: "2025-01-01", value: "2025-01-01" },
          { identifier: "end_date", type: "date", default: "2025-12-31", value: "2025-12-31" },
        ],
      });

      const report = { id: 13, name: "Date Params", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      await click(".insights-report-chart__toggle-btn");

      assert
        .dom(".insights-report-chart__params")
        .exists("params section renders");
      assert
        .dom(".insights-report-chart__param-input[type='date']")
        .exists({ count: 2 }, "renders 2 date inputs");
      assert
        .dom(".insights-report-chart__param-input[type='date']")
        .hasValue("2025-01-01");
      assert
        .dom(".insights-report-chart__run-btn")
        .exists("run button renders");
    });

    test("re-run button re-fetches with new params", async function (assert) {
      let callCount = 0;
      pretender.get("/insights/reports/14/run.json", (request) => {
        callCount++;
        if (callCount === 1) {
          return response({
            columns: ["week", "count"],
            rows: [["2025-01-06", 10]],
            params: [
              { identifier: "start_date", type: "date", default: "2025-01-01", value: "2025-01-01" },
            ],
          });
        }
        return response({
          columns: ["week", "count"],
          rows: [
            ["2025-06-01", 50],
            ["2025-06-08", 60],
          ],
          params: [
            { identifier: "start_date", type: "date", default: "2025-01-01", value: request.queryParams.start_date },
          ],
        });
      });

      const report = { id: 14, name: "Re-run Test", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      assert.strictEqual(callCount, 1, "initial fetch happened");

      await click(".insights-report-chart__toggle-btn");
      await fillIn(".insights-report-chart__param-input[type='date']", "2025-06-01");
      await click(".insights-report-chart__run-btn");

      assert.strictEqual(callCount, 2, "re-run triggered second fetch");

      assert
        .dom(".insights-report-chart__table tbody tr:nth-child(1) td:nth-child(1)")
        .hasText("2025-06-01", "table updated with new data");
    });

    test("non-editable params render as read-only chips", async function (assert) {
      mockRun(15, {
        columns: ["name", "count"],
        rows: [["Alice", 42]],
        params: [
          { identifier: "user_id", type: "user_id", default: "1", value: "1" },
          { identifier: "start_date", type: "date", default: "2025-01-01", value: "2025-01-01" },
        ],
      });

      const report = { id: 15, name: "Mixed Params", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      await click(".insights-report-chart__toggle-btn");

      assert
        .dom(".insights-report-chart__param-chip")
        .exists({ count: 1 }, "one read-only chip for user_id");
      assert
        .dom(".insights-report-chart__param-chip")
        .hasText("user_id: 1");
      assert
        .dom(".insights-report-chart__param-input[type='date']")
        .exists({ count: 1 }, "one editable date input");
    });

    test("run button is disabled during re-run", async function (assert) {
      let resolveSecondCall;
      let callCount = 0;

      pretender.get("/insights/reports/16/run.json", () => {
        callCount++;
        if (callCount === 1) {
          return response({
            columns: ["week", "count"],
            rows: [["2025-01-06", 10]],
            params: [
              { identifier: "start_date", type: "date", default: "2025-01-01", value: "2025-01-01" },
            ],
          });
        }
        return new Promise((resolve) => {
          resolveSecondCall = resolve;
        });
      });

      const report = { id: 16, name: "Disabled Test", insights: false };
      await render(
        <template><InsightsReportChart @report={{report}} /></template>
      );

      await click(".insights-report-chart__toggle-btn");

      const clickPromise = click(".insights-report-chart__run-btn");

      await new Promise((resolve) => setTimeout(resolve, 50));

      assert
        .dom(".insights-report-chart__run-btn")
        .isDisabled("run button disabled during fetch");

      resolveSecondCall(
        response({
          columns: ["week", "count"],
          rows: [["2025-01-06", 10]],
          params: [
            { identifier: "start_date", type: "date", default: "2025-01-01", value: "2025-01-01" },
          ],
        })
      );

      await clickPromise;

      assert
        .dom(".insights-report-chart__run-btn")
        .isNotDisabled("run button re-enabled after fetch");
    });

    test("@readonly hides remove button and grip icon, chart still renders", async function (assert) {
      mockRun(17, {
        columns: ["week", "count"],
        rows: [
          ["2025-01-06", 10],
          ["2025-01-13", 20],
        ],
        params: [
          { identifier: "start_date", type: "date", default: "2025-01-01", value: "2025-01-01" },
        ],
      });

      const report = { id: 17, name: "Readonly Test", insights: false };
      await render(
        <template>
          <InsightsReportChart @report={{report}} @readonly={{true}} />
        </template>
      );

      assert
        .dom(".insights-report-chart__canvas-wrap canvas")
        .exists("chart still renders in readonly mode");
      assert
        .dom(".insights-report-chart__title")
        .hasText("Readonly Test");
      assert
        .dom(".insights-report-chart__remove")
        .doesNotExist("remove button hidden in readonly mode");
      assert
        .dom(".insights-report-chart__grip")
        .doesNotExist("grip icon hidden in readonly mode");

      await click(".insights-report-chart__toggle-btn");

      assert
        .dom(".insights-report-chart__run-btn")
        .doesNotExist("run button hidden in readonly mode");
      assert
        .dom(".insights-report-chart__param-input")
        .doesNotExist("param inputs hidden in readonly mode");
      assert
        .dom(".insights-report-chart__param-chip")
        .exists({ count: 1 }, "params shown as read-only chips");
    });
  }
);
