import { describe, expect, it } from "vitest";
import ImageCropWidget from "@/components/image_crop_widget.vue";

type Sel = { x: number; y: number; w: number; h: number };
type Widget = {
  displayW: number;
  displayH: number;
  naturalWidth: number;
  naturalHeight: number;
  aspectRatio: number | null;
  selection: Sel | null;
  scale: number;
};

// The widget's own methods and computed values, run against a given display state.
const { clampSel, constrainSel } = (ImageCropWidget as any).methods;
const { scale, sourceSel } = (ImageCropWidget as any).computed;

function widget (state: Partial<Widget>): Widget & { clampSel: typeof clampSel } {
  const self: any = { displayW: 800, displayH: 600, naturalWidth: 800, naturalHeight: 600, aspectRatio: 1, selection: null, ...state };
  self.clampSel = clampSel.bind(self);
  self.scale = scale.call(self);
  return self;
}

describe("ImageCropWidget", () => {
  it("keeps a square selection square when it is dragged past the image", () => {
    const self = widget({});
    expect(constrainSel.call(self, 0, 0, 800, 800)).toEqual({ x: 0, y: 0, w: 600, h: 600 });
  });

  it("leaves free selections clamped per side", () => {
    const self = widget({ aspectRatio: null });
    expect(constrainSel.call(self, 0, 0, 900, 700)).toEqual({ x: 0, y: 0, w: 800, h: 600 });
  });

  it("keeps the rounded source selection inside the image", () => {
    // Shown at a quarter size, this selection reaches the right edge at x 250.5 + width 749.5,
    // which rounds to 251 + 750, one pixel past the image.
    const self = widget({ naturalWidth: 1000, naturalHeight: 750, displayW: 250, displayH: 187.5 });
    self.selection = { x: 62.625, y: 0, w: 187.375, h: 187.375 };

    expect(sourceSel.call(self)).toEqual({ x: 251, y: 0, w: 749, h: 749 });
  });
});
