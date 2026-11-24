import ImageCropWidget from "@/components/image_crop_widget.vue";
import { App, createApp } from "vue";

/**
 * Lets the user pick the part of an image to upload as their avatar.
 * The image is shown from the local file, so nothing is uploaded until the form is sent.
 * Coordinates are in pixels of the image as displayed, which is what the server expects.
 */
export function setupAvatarUploadCrop (): void {
  const input = document.getElementById("avatar_file") as HTMLInputElement | null;
  const widgetEl = document.getElementById("avatar-upload-crop-widget");
  if (!input || !widgetEl) return;

  const hint = document.getElementById("avatar-upload-crop-hint");
  const fields = ["x", "y", "w"].map((key) => document.getElementById(`avatar_crop_${key}`) as HTMLInputElement | null);
  const minSize = parseInt(widgetEl.dataset.minSize ?? "", 10) || 0;

  let app: App | null = null;
  let objectUrl: string | null = null;

  const reset = () => {
    app?.unmount();
    app = null;
    if (objectUrl) URL.revokeObjectURL(objectUrl);
    objectUrl = null;
    for (const field of fields) if (field) field.value = "";
    if (hint) hint.hidden = true;
  };

  input.addEventListener("change", () => {
    reset();

    const file = input.files?.[0];
    if (!file || !file.type.startsWith("image/")) return;

    const url = URL.createObjectURL(file);
    objectUrl = url;

    const probe = new Image();
    probe.onload = () => {
      // Another file was chosen while this one loaded
      if (objectUrl !== url || !probe.naturalWidth || !probe.naturalHeight) return;

      app = createApp(ImageCropWidget, {
        imageUrl: url,
        naturalWidth: probe.naturalWidth,
        naturalHeight: probe.naturalHeight,
        aspectRatio: 1,
        minSize: Math.min(minSize, probe.naturalWidth, probe.naturalHeight),
        onCropChange (coords: { x: number; y: number; w: number; h: number }) {
          // A click without a drag selects nothing, which falls back to the center
          const values = coords.w > 0 ? [coords.x, coords.y, coords.w].map(String) : ["", "", ""];
          fields.forEach((field, i) => { if (field) field.value = values[i]; });
        },
      });
      app.mount(widgetEl);
      if (hint) hint.hidden = false;
    };
    probe.src = url;
  });
}

$(() => setupAvatarUploadCrop());
