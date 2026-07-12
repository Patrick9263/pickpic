export interface GeneratedImageVariant {
  blob: Blob;
  width: number;
  height: number;
}

export interface GeneratedImageVariants {
  thumbnail: GeneratedImageVariant;
  preview: GeneratedImageVariant;
}

const THUMBNAIL_MAX_EDGE = 768;
const THUMBNAIL_QUALITY = 0.78;

const PREVIEW_MAX_EDGE = 2048;
const PREVIEW_QUALITY = 0.85;

function getScaledDimensions(
  width: number,
  height: number,
  maximumEdge: number,
): {
  width: number;
  height: number;
} {
  const longestEdge = Math.max(width, height);

  if (longestEdge <= maximumEdge) {
    return {
      width,
      height,
    };
  }

  const scale = maximumEdge / longestEdge;

  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

function createCanvas(width: number, height: number): HTMLCanvasElement {
  const canvas = document.createElement("canvas");

  canvas.width = width;
  canvas.height = height;

  return canvas;
}

function canvasToJpegBlob(
  canvas: HTMLCanvasElement,
  quality: number,
): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (!blob) {
          reject(new Error("The browser could not create an optimized JPEG."));

          return;
        }

        resolve(blob);
      },
      "image/jpeg",
      quality,
    );
  });
}

function drawImage(
  canvas: HTMLCanvasElement,
  source: CanvasImageSource | HTMLCanvasElement,
): void {
  const context = canvas.getContext("2d");

  if (!context) {
    throw new Error("The browser could not create an image canvas.");
  }

  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";

  context.drawImage(source, 0, 0, canvas.width, canvas.height);
}

export async function generateImageVariants(
  file: File,
): Promise<GeneratedImageVariants> {
  const sourceBitmap = await createImageBitmap(file, {
    imageOrientation: "from-image",
  });

  try {
    const previewDimensions = getScaledDimensions(
      sourceBitmap.width,
      sourceBitmap.height,
      PREVIEW_MAX_EDGE,
    );

    const previewCanvas = createCanvas(
      previewDimensions.width,
      previewDimensions.height,
    );

    drawImage(previewCanvas, sourceBitmap);

    /*
     * Create the thumbnail from the already-reduced preview
     * canvas instead of scaling the full source a second time.
     */
    const thumbnailDimensions = getScaledDimensions(
      sourceBitmap.width,
      sourceBitmap.height,
      THUMBNAIL_MAX_EDGE,
    );

    const thumbnailCanvas = createCanvas(
      thumbnailDimensions.width,
      thumbnailDimensions.height,
    );

    drawImage(thumbnailCanvas, previewCanvas);

    const [previewBlob, thumbnailBlob] = await Promise.all([
      canvasToJpegBlob(previewCanvas, PREVIEW_QUALITY),
      canvasToJpegBlob(thumbnailCanvas, THUMBNAIL_QUALITY),
    ]);

    return {
      thumbnail: {
        blob: thumbnailBlob,
        width: thumbnailDimensions.width,
        height: thumbnailDimensions.height,
      },
      preview: {
        blob: previewBlob,
        width: previewDimensions.width,
        height: previewDimensions.height,
      },
    };
  } finally {
    /*
     * Important for large 61 MP camera images.
     */
    sourceBitmap.close();
  }
}
