import Component from "@glimmer/component";
import DModal from "discourse/components/d-modal";
import { i18n } from "discourse-i18n";

export default class InsightsComingSoonModal extends Component {
  <template>
    <DModal
      class="insights-coming-soon-modal"
      @title={{i18n "discourse_insights.live.coming_soon_title"}}
      @closeModal={{@closeModal}}
    >
      <:body>
        <p>{{i18n "discourse_insights.live.coming_soon_body"}}</p>
      </:body>
    </DModal>
  </template>
}
