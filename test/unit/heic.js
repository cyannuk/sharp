/*!
  Copyright 2013 Lovell Fuller and others.
  SPDX-License-Identifier: Apache-2.0
*/

const fs = require('node:fs');
const { suite, test } = require('node:test');

const sharp = require('../../');
const { inputAvif, inputHeic, inputJpg } = require('../fixtures');

// Requires libvips built with libde265, see scripts/libvips-heic
const skip = !sharp.versions.de265 && 'libvips was not built with HEVC decoding support';

suite('HEIC and decode-only libvips build', { skip }, () => {
  test('HEIC input is available, HEIF output is not', (t) => {
    t.plan(4);
    t.assert.strictEqual(sharp.format.heif.input.file, true);
    t.assert.strictEqual(sharp.format.heif.input.buffer, true);
    t.assert.deepStrictEqual(sharp.format.heif.input.fileSuffix, ['.avif', '.heic', '.heif']);
    t.assert.deepStrictEqual(sharp.format.heif.output, { file: false, buffer: false, stream: false, alias: [] });
  });

  test('only the required formats are available', (t) => {
    const input = Object.keys(sharp.format).filter((id) => sharp.format[id].input.file);
    const output = Object.keys(sharp.format).filter((id) => sharp.format[id].output.buffer);
    t.assert.deepStrictEqual(input.sort(), ['heif', 'jpeg', 'png', 'tiff', 'vips', 'webp']);
    t.assert.ok(output.includes('webp'));
    t.assert.ok(!output.includes('heif') && !output.includes('gif'));
  });

  test('can convert HEIC to WebP', async (t) => {
    t.plan(3);
    const { data, info } = await sharp(inputHeic).webp().toBuffer({ resolveWithObject: true });
    t.assert.strictEqual(info.format, 'webp');
    t.assert.strictEqual(info.width, 320);
    const { format } = await sharp(data).metadata();
    t.assert.strictEqual(format, 'webp');
  });

  test('can convert AVIF to WebP', async (t) => {
    t.plan(2);
    const { info } = await sharp(inputAvif).webp().toBuffer({ resolveWithObject: true });
    t.assert.strictEqual(info.format, 'webp');
    t.assert.strictEqual(info.width, 2048);
  });

  test('metadata', async (t) => {
    t.plan(1);
    const { size, ...metadata } = await sharp(inputHeic).metadata();
    void size;
    t.assert.deepStrictEqual(metadata, {
      autoOrient: {
        height: 240,
        width: 320,
      },
      channels: 3,
      compression: 'hevc',
      depth: 'uchar',
      format: 'heif',
      hasAlpha: false,
      hasProfile: false,
      height: 240,
      isProgressive: false,
      isPalette: false,
      bitsPerSample: 8,
      mediaType: 'image/heic',
      pagePrimary: 0,
      pages: 1,
      space: 'srgb',
      width: 320,
    });
  });

  test('can convert HEIC file to JPEG', async (t) => {
    t.plan(3);
    const { data, info } = await sharp(inputHeic).resize(160).jpeg().toBuffer({ resolveWithObject: true });
    t.assert.strictEqual(info.format, 'jpeg');
    t.assert.strictEqual(info.width, 160);
    t.assert.strictEqual(info.height, 120);
    void data;
  });

  test('can convert HEIC Buffer to PNG', async (t) => {
    t.plan(2);
    const input = fs.readFileSync(inputHeic);
    const { info } = await sharp(input).png().toBuffer({ resolveWithObject: true });
    t.assert.strictEqual(info.format, 'png');
    t.assert.strictEqual(info.width, 320);
  });

  test('decoded pixels are close to the original', async (t) => {
    t.plan(1);
    const [heic, original] = await Promise.all([
      sharp(inputHeic).raw().toBuffer(),
      sharp(inputJpg).resize(320, 240, { fit: 'fill' }).raw().toBuffer(),
    ]);
    let diff = 0;
    for (let i = 0; i < heic.length; i++) {
      diff += Math.abs(heic[i] - original[i]);
    }
    t.assert.ok(diff / heic.length < 8, `mean absolute difference ${diff / heic.length}`);
  });

  for (const compression of ['hevc', 'av1']) {
    test(`${compression} output is not supported`, async (t) => {
      t.plan(1);
      await t.assert.rejects(sharp(inputJpg).resize(32).heif({ compression }).toBuffer(), /Unsupported compression/);
    });
  }
});
