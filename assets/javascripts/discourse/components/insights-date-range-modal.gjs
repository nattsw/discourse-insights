/* eslint-disable ember/no-tracked-properties-from-args */
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import DateTimeInputRange from "discourse/components/date-time-input-range";
import { i18n } from "discourse-i18n";

export default class InsightsDateRangeModal extends Component {
  @tracked startDate = this.args.model.startDate;
  @tracked endDate = this.args.model.endDate;

  @action
  onChangeDateRange(range) {
    this.startDate = range.from;
    this.endDate = range.to;
  }

  @action
  apply() {
    this.args.model.setCustomDateRange(this.startDate, this.endDate);
    this.args.closeModal();
  }

  <template>
    <DModal
      class="insights-date-range-modal"
      @title={{i18n "discourse_insights.date_range_title"}}
      @closeModal={{@closeModal}}
    >
      <:body>
        <DateTimeInputRange
          @from={{this.startDate}}
          @to={{this.endDate}}
          @onChange={{this.onChangeDateRange}}
          @showFromTime={{false}}
          @showToTime={{false}}
        />
      </:body>
      <:footer>
        <DButton
          @action={{this.apply}}
          @label="discourse_insights.date_range_apply"
          @icon="arrows-rotate"
          class="btn-primary"
        />
      </:footer>
    </DModal>
  </template>
}
