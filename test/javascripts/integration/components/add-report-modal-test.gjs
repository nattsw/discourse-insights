import { fillIn, render, settled } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import AddReportModal from "../../discourse/components/add-report-modal";

function mockAvailable(queries) {
  pretender.get("/insights/reports/available.json", () =>
    response({ queries })
  );
}

const QUERIES = [
  { id: 1, name: "Weekly Users", description: "Active users per week", insights: true, pinned: false },
  { id: 2, name: "Topic Growth", description: "New topics over time", insights: false, pinned: false },
  { id: 3, name: "Category Breakdown", description: null, insights: false, pinned: false },
  { id: 4, name: "Pinned Query", description: "Should not show", insights: false, pinned: true },
];

module(
  "Discourse Insights | Integration | Component | add-report-modal",
  function (hooks) {
    setupRenderingTest(hooks);

    hooks.beforeEach(function () {
      const modalContainer = document.createElement("div");
      modalContainer.id = "discourse-modal";
      document.getElementById("ember-testing").appendChild(modalContainer);
      this.owner.lookup("service:modal").containerElement = modalContainer;
    });

    async function renderModal() {
      const model = {};
      const closeModal = () => {};
      await render(
        <template>
          <AddReportModal @model={{model}} @closeModal={{closeModal}} />
        </template>
      );
      await settled();
    }

    test("renders filter input and all unpinned queries", async function (assert) {
      mockAvailable(QUERIES);
      await renderModal();

      assert
        .dom(".add-report-modal__filter")
        .exists("filter input is rendered");
      assert
        .dom(".add-report-modal__item")
        .exists({ count: 3 }, "shows 3 unpinned queries");
    });

    test("filters queries by name", async function (assert) {
      mockAvailable(QUERIES);
      await renderModal();

      await fillIn(".add-report-modal__filter", "weekly");

      assert
        .dom(".add-report-modal__item")
        .exists({ count: 1 }, "only matching query shown");
      assert
        .dom(".add-report-modal__name")
        .hasText(/Weekly Users/);
    });

    test("does not filter by description", async function (assert) {
      mockAvailable(QUERIES);
      await renderModal();

      await fillIn(".add-report-modal__filter", "new topics");

      assert
        .dom(".add-report-modal__item")
        .doesNotExist("description text does not match");
    });

    test("shows empty state when filter matches nothing", async function (assert) {
      mockAvailable(QUERIES);
      await renderModal();

      await fillIn(".add-report-modal__filter", "zzzznotfound");

      assert
        .dom(".add-report-modal__item")
        .doesNotExist("no items shown");
      assert
        .dom(".add-report-modal__empty")
        .exists("empty state message shown");
    });

    test("filter is case-insensitive", async function (assert) {
      mockAvailable(QUERIES);
      await renderModal();

      await fillIn(".add-report-modal__filter", "CATEGORY");

      assert
        .dom(".add-report-modal__item")
        .exists({ count: 1 }, "case-insensitive match works");
    });

    test("clearing filter restores all queries", async function (assert) {
      mockAvailable(QUERIES);
      await renderModal();

      await fillIn(".add-report-modal__filter", "weekly");
      assert
        .dom(".add-report-modal__item")
        .exists({ count: 1 });

      await fillIn(".add-report-modal__filter", "");
      assert
        .dom(".add-report-modal__item")
        .exists({ count: 3 }, "all unpinned queries restored");
    });
  }
);
