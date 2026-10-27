import { LightningElement, api } from "lwc";

// How each step state shows in the card header.
const STATES = {
  complete: { badgeLabel: "Done", badgeClass: "slds-theme_success" },
  current: { badgeLabel: "Next step", badgeClass: "slds-badge_inverse" },
  upcoming: { badgeLabel: "Not started", badgeClass: "" }
};

/**
 * One numbered section of the GitHub MCP Setup page. The header shows the
 * step's state; the body comes from the default slot.
 */
export default class GithubMcpSetupStep extends LightningElement {
  @api number;
  @api label;
  /** One of `complete`, `current`, or `upcoming`. */
  @api state = "upcoming";

  get stateConfig() {
    return STATES[this.state] || STATES.upcoming;
  }

  get isComplete() {
    return this.state === "complete";
  }

  get badgeLabel() {
    return this.stateConfig.badgeLabel;
  }

  get badgeClass() {
    return this.stateConfig.badgeClass;
  }

  get markerClass() {
    return `step-marker step-marker_${this.state}`;
  }
}
