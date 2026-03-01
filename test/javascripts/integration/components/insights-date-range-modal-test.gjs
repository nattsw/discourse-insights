import { click, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import InsightsDateRangeModal from "../../discourse/components/insights-date-range-modal";

module(
  "Discourse Insights | Integration | Component | insights-date-range-modal",
  function (hooks) {
    setupRenderingTest(hooks);

    hooks.beforeEach(function () {
      const modalContainer = document.createElement("div");
      modalContainer.id = "discourse-modal";
      document.getElementById("ember-testing").appendChild(modalContainer);
      this.owner.lookup("service:modal").containerElement = modalContainer;
    });

    test("renders with initial dates", async function (assert) {
      const startDate = moment("2026-01-01");
      const endDate = moment("2026-01-31");
      const model = {
        startDate,
        endDate,
        setCustomDateRange: () => {},
      };
      const closeModal = () => {};

      await render(
        <template>
          <InsightsDateRangeModal @model={{model}} @closeModal={{closeModal}} />
        </template>
      );

      assert
        .dom(".insights-date-range-modal")
        .exists("modal renders");
      assert
        .dom(".btn-primary")
        .exists("apply button renders");
    });

    test("apply calls setCustomDateRange and closes modal", async function (assert) {
      const startDate = moment("2026-02-01");
      const endDate = moment("2026-02-28");
      let calledWith = null;
      let modalClosed = false;

      const model = {
        startDate,
        endDate,
        setCustomDateRange: (s, e) => {
          calledWith = { start: s, end: e };
        },
      };
      const closeModal = () => {
        modalClosed = true;
      };

      await render(
        <template>
          <InsightsDateRangeModal @model={{model}} @closeModal={{closeModal}} />
        </template>
      );

      await click(".btn-primary");

      assert.notStrictEqual(calledWith, null, "setCustomDateRange was called");
      assert.true(modalClosed, "modal was closed");
    });
  }
);
