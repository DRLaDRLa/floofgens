import { createApp } from "vue";
import Uploader from "./uploader.vue";

import DeletionExamples from "@/pages/uploads/new/DeletionExamples";

const UploaderModule = {
  init () {
    const uploaderElement = document.getElementById("uploader");
    if (!uploaderElement) return;

    const app = createApp(Uploader);
    app.mount("#uploader");
  },
};

$(() => {
  UploaderModule.init();
  void DeletionExamples.instance;
});

export default UploaderModule;
