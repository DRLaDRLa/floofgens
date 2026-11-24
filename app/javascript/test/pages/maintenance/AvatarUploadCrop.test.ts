import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { tick } from "../../helpers";

// jsdom does not decode images, so loading one is faked with fixed dimensions.
class FakeImage {
  public naturalWidth = 800;
  public naturalHeight = 600;
  public onload: (() => void) | null = null;
  set src (_value: string) { queueMicrotask(() => this.onload?.()); }
}

function buildPage () {
  document.body.innerHTML = `
    <input type="file" id="avatar_file">
    <div id="avatar-upload-crop-widget" data-min-size="64"></div>
    <p id="avatar-upload-crop-hint" hidden></p>
    <input type="hidden" id="avatar_crop_x">
    <input type="hidden" id="avatar_crop_y">
    <input type="hidden" id="avatar_crop_w">
  `;
}

function choose (input: HTMLInputElement, file: File | null) {
  Object.defineProperty(input, "files", { value: file ? [file] : [], configurable: true });
  input.dispatchEvent(new Event("change"));
}

describe("AvatarUploadCrop", () => {
  let input: HTMLInputElement;

  beforeEach(async () => {
    vi.stubGlobal("Image", FakeImage);
    let counter = 0;
    URL.createObjectURL = vi.fn(() => `blob:avatar-${++counter}`);
    URL.revokeObjectURL = vi.fn();
    buildPage();
    input = document.getElementById("avatar_file") as HTMLInputElement;
    await import("@/pages/maintenance/user/avatars/AvatarUploadCrop");
    await tick();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    document.body.innerHTML = "";
  });

  it("shows the crop widget for the chosen image", async () => {
    choose(input, new File(["x"], "fox.png", { type: "image/png" }));
    await tick();

    const img = document.querySelector<HTMLImageElement>("#avatar-upload-crop-widget .image-crop-widget img");
    expect(img).not.toBeNull();
    expect(img!.getAttribute("src")).toBe("blob:avatar-1");
    expect(document.getElementById("avatar-upload-crop-hint")!.hidden).toBe(false);
  });

  it("ignores files that aren't images", async () => {
    choose(input, new File(["x"], "notes.txt", { type: "text/plain" }));
    await tick();

    expect(document.querySelector(".image-crop-widget")).toBeNull();
    expect(URL.createObjectURL).not.toHaveBeenCalled();
  });

  it("clears the previous image and selection when the file changes", async () => {
    choose(input, new File(["x"], "fox.png", { type: "image/png" }));
    await tick();
    (document.getElementById("avatar_crop_w") as HTMLInputElement).value = "100";

    choose(input, null);
    await tick();

    expect(document.querySelector(".image-crop-widget")).toBeNull();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:avatar-1");
    expect((document.getElementById("avatar_crop_w") as HTMLInputElement).value).toBe("");
    expect(document.getElementById("avatar-upload-crop-hint")!.hidden).toBe(true);
  });
});
