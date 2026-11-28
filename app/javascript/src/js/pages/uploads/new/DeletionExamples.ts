
import CStorage from "@/utility/storage/Cookie";

export default class DeletionExamples {

  /* ============================== */
  /* ===== Singleton pattern ====== */
  /* ============================== */

  private static _instance: DeletionExamples | null = null;
  public static get instance (): DeletionExamples {
    if (!DeletionExamples._instance)
      DeletionExamples._instance = new DeletionExamples();
    return DeletionExamples._instance;
  }

  private wrapper: JQuery<HTMLElement>;
  private toggle: JQuery<HTMLElement>;

  private constructor () {
    if (DeletionExamples._instance)
      throw new Error("DeletionExamples is a singleton class. Use DeletionExamples.instance to access the instance.");

    this.wrapper = $("#deletion-examples");
    this.toggle = $("#deletion-examples-toggle button");

    this.toggle.on("click", () => {
      this.visible = !this.visible;
    });
  }

  public get visible (): boolean {
    return !CStorage.Posts.DeletionExamplesHidden;
  }

  public set visible (value: boolean) {
    CStorage.Posts.DeletionExamplesHidden = !value;
    this.wrapper.attr("data-visible", value ? "true" : "false");
    this.toggle.attr({
      "aria-expanded": value ? "true" : "false",
      "aria-label": value ? "Hide Deletion Examples" : "Show Deletion Examples",
    });
  }
}
