import ExifReader from "exifreader";

export interface ExtractedPhotoMetadata {
  capturedAt: string | null;
  latitude: number | null;
  longitude: number | null;
}

interface ExifTag {
  description?: string;
  value?: unknown;
}

interface ExpandedExifTags {
  exif?: Record<string, ExifTag>;
  gps?: {
    Latitude?: number;
    Longitude?: number;
  };
}

function normalizeExifDate(value: string): string | null {
  const match =
    /^(\d{4})[:-](\d{2})[:-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(
      value.trim(),
    );

  if (!match) {
    return null;
  }

  const [, yearText, monthText, dayText, hourText, minuteText, secondText] =
    match;

  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);

  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second));

  const isValid =
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day &&
    date.getUTCHours() === hour &&
    date.getUTCMinutes() === minute &&
    date.getUTCSeconds() === second;

  if (!isValid) {
    return null;
  }

  return [
    yearText,
    "-",
    monthText,
    "-",
    dayText,
    "T",
    hourText,
    ":",
    minuteText,
    ":",
    secondText,
  ].join("");
}

function getTagText(tag: ExifTag | undefined): string | null {
  if (!tag) {
    return null;
  }

  if (typeof tag.description === "string") {
    return tag.description;
  }

  if (typeof tag.value === "string") {
    return tag.value;
  }

  if (Array.isArray(tag.value) && typeof tag.value[0] === "string") {
    return tag.value[0];
  }

  return null;
}

export async function extractPhotoMetadata(
  file: File,
): Promise<ExtractedPhotoMetadata> {
  try {
    const tags = (await ExifReader.load(file, {
      expanded: true,
      includeOffsets: true,
      length: "auto",
      excludeTags: {
        mpf: true,
        makerNotes: true,
        thumbnail: true,
      },
    })) as unknown as ExpandedExifTags;

    const dateTag =
      tags.exif?.DateTimeOriginal ??
      tags.exif?.DateTimeDigitized ??
      tags.exif?.DateTime;

    const dateText = getTagText(dateTag);

    const latitude =
      typeof tags.gps?.Latitude === "number" &&
      Number.isFinite(tags.gps.Latitude)
        ? tags.gps.Latitude
        : null;

    const longitude =
      typeof tags.gps?.Longitude === "number" &&
      Number.isFinite(tags.gps.Longitude)
        ? tags.gps.Longitude
        : null;

    return {
      capturedAt: dateText ? normalizeExifDate(dateText) : null,
      latitude,
      longitude,
    };
  } catch (error) {
    /*
     * Missing or unsupported metadata should not prevent an
     * otherwise valid JPG from uploading.
     */
    console.warn(`Unable to read metadata from ${file.name}:`, error);

    return {
      capturedAt: null,
      latitude: null,
      longitude: null,
    };
  }
}
