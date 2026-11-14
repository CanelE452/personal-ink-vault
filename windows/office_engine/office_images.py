"""Bounded, owned embedded PNG/JPEG assets and native image previews."""
import base64
import hashlib
from pathlib import Path
import re
import struct
import zlib

MAX_BYTES = 20 * 1024 * 1024
MAX_PIXELS = 40 * 1000 * 1000
MAX_BATCH_BYTES = 80 * 1024 * 1024
THUMBNAIL_BYTES = 256 * 1024
THUMBNAIL_BUDGET = 2 * 1024 * 1024
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')


def dimensions(data, mime):
    if mime == 'image/png':
        if len(data) < 33 or data[:8] != b'\x89PNG\r\n\x1a\n' or data[8:16] != b'\x00\x00\x00\rIHDR':
            raise ValueError('Invalid Office PNG header')
        width, height = struct.unpack('>II', data[16:24])
        offset, has_pixels, ended = 8, False, False
        while offset + 12 <= len(data):
            size = struct.unpack('>I', data[offset:offset + 4])[0]
            kind = data[offset + 4:offset + 8]
            end = offset + 12 + size
            if end > len(data) or zlib.crc32(data[offset + 4:end - 4]) != struct.unpack('>I', data[end - 4:end])[0]:
                raise ValueError('Corrupt Office PNG chunk')
            if kind == b'acTL':
                raise ValueError('Animated PNG photos are not supported')
            has_pixels |= kind == b'IDAT'
            offset = end
            if kind == b'IEND':
                ended = size == 0
                break
        if not has_pixels or not ended:
            raise ValueError('Incomplete Office PNG')
        return width, height
    if mime != 'image/jpeg' or len(data) < 4 or data[:2] != b'\xff\xd8':
        raise ValueError('Office photo must be PNG or JPEG')
    offset = 2
    while offset < len(data):
        if data[offset] != 255:
            raise ValueError('Invalid Office JPEG marker')
        while offset < len(data) and data[offset] == 255:
            offset += 1
        if offset >= len(data):
            break
        marker, offset = data[offset], offset + 1
        if marker in (0xDA, 0xD9):
            break
        if marker == 0x01 or 0xD0 <= marker <= 0xD8:
            continue
        if offset + 2 > len(data):
            break
        size = struct.unpack('>H', data[offset:offset + 2])[0]
        if size < 2 or offset + size > len(data):
            raise ValueError('Invalid Office JPEG segment')
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            if size < 8:
                raise ValueError('Invalid Office JPEG frame')
            height, width = struct.unpack('>HH', data[offset + 3:offset + 7])
            return width, height
        offset += size
    raise ValueError('Missing Office JPEG dimensions')


def read_assets(entries, root):
    if not isinstance(entries, list) or len(entries) > 256:
        raise ValueError('Invalid Office image asset list')
    assets, total = {}, 0
    if not entries:
        return assets
    root = Path(root).resolve(strict=True)
    asset_directory = root / 'assets'
    if asset_directory.is_symlink() or getattr(asset_directory, 'is_junction', lambda: False)():
        raise ValueError('Linked Office asset directory is not allowed')
    fields = {'id', 'fileName', 'mimeType', 'byteLength', 'sha256', 'width', 'height'}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != fields:
            raise ValueError('Invalid Office image asset fields')
        identifier, mime = entry['id'], entry['mimeType']
        extension = {'image/png': '.png', 'image/jpeg': '.jpg'}.get(mime)
        if not isinstance(identifier, str) or not UUID.fullmatch(identifier) or identifier in assets or extension is None:
            raise ValueError('Invalid Office image asset identity or MIME')
        if entry['fileName'] != 'assets/' + identifier + extension:
            raise ValueError('Office image path is outside its owned asset identity')
        path = asset_directory / (identifier + extension)
        if path.is_symlink() or not path.is_file() or path.resolve(strict=True).parent != asset_directory.resolve(strict=True):
            raise ValueError('Office image path is not an owned regular file')
        size = entry['byteLength']
        if type(size) is not int or not 0 < size <= MAX_BYTES or path.stat().st_size != size:
            raise ValueError('Invalid Office image byte length')
        total += size
        if total > MAX_BATCH_BYTES:
            raise ValueError('Office image batch exceeds 80 MiB')
        with path.open('rb') as stream:
            payload = stream.read(MAX_BYTES + 1)
        if len(payload) != size or hashlib.sha256(payload).hexdigest() != entry['sha256']:
            raise ValueError('Office image asset checksum mismatch')
        width, height = dimensions(payload, mime)
        if type(entry['width']) is not int or type(entry['height']) is not int or (width, height) != (entry['width'], entry['height']):
            raise ValueError('Office image dimensions mismatch')
        if width < 1 or height < 1 or width * height > MAX_PIXELS:
            raise ValueError('Office image exceeds 40 million pixels')
        assets[identifier] = {**entry, 'bytes': payload}
    return assets


def load_graphic(context, asset, prop, uno):
    stream = context.ServiceManager.createInstanceWithContext('com.sun.star.io.SequenceInputStream', context)
    stream.initialize((uno.ByteSequence(asset['bytes']),))
    provider = context.ServiceManager.createInstanceWithContext('com.sun.star.graphic.GraphicProvider', context)
    graphic = provider.queryGraphic((prop('InputStream', stream),))
    if graphic is None or graphic.MimeType != asset['mimeType'] or (
            graphic.SizePixel.Width, graphic.SizePixel.Height) != (asset['width'], asset['height']):
        raise ValueError('Native Office photo decoder did not match the verified asset')
    return graphic


def image_details(context, shape, prop, uno, budget):
    graphic = shape.Graphic
    result = {'mimeType': None, 'pixelWidth': None, 'pixelHeight': None,
              'canReplace': True, 'thumbnailTruncated': True}
    if graphic is None:
        return result
    result.update({'mimeType': graphic.MimeType, 'pixelWidth': graphic.SizePixel.Width,
                   'pixelHeight': graphic.SizePixel.Height})
    if context is None or budget[0] <= 0:
        return result
    stream = None
    try:
        width, height = graphic.SizePixel.Width, graphic.SizePixel.Height
        scale = min(1, 224 / max(width, height, 1))
        options = (prop('PixelWidth', max(1, round(width * scale))),
                   prop('PixelHeight', max(1, round(height * scale))))
        stream = context.ServiceManager.createInstanceWithContext('com.sun.star.io.TempFile', context)
        stream.RemoveFile = True
        provider = context.ServiceManager.createInstanceWithContext('com.sun.star.graphic.GraphicProvider', context)
        provider.storeGraphic(graphic, (prop('OutputStream', stream), prop('MimeType', 'image/png'),
            prop('FilterData', uno.Any('[]com.sun.star.beans.PropertyValue', options))))
        size = stream.getLength()
        if not 0 < size <= min(THUMBNAIL_BYTES, budget[0]):
            return result
        stream.seek(0)
        count, sequence = stream.getInputStream().readBytes(None, size)
        payload = bytes(sequence)
        if count != size or len(payload) != size:
            return result
        thumbnail_width, thumbnail_height = dimensions(payload, 'image/png')
        if not 0 < thumbnail_width <= 224 or not 0 < thumbnail_height <= 224:
            return result
        budget[0] -= len(payload)
        result.update({'thumbnailBase64': base64.b64encode(payload).decode('ascii'),
            'thumbnailMimeType': 'image/png', 'thumbnailSha256': hashlib.sha256(payload).hexdigest(),
            'thumbnailTruncated': False})
    except Exception:
        pass
    finally:
        if stream is not None:
            for accessor, close in (('getInputStream', 'closeInput'), ('getOutputStream', 'closeOutput')):
                try:
                    getattr(getattr(stream, accessor)(), close)()
                except Exception:
                    pass
    return result


def replace_graphic(shape, graphic):
    if not shape.supportsService('com.sun.star.drawing.GraphicObjectShape'):
        raise ValueError('This Office object is not a replaceable photo')
    before = (shape.Position.X, shape.Position.Y, shape.Size.Width, shape.Size.Height,
              shape.RotateAngle, shape.ZOrder, shape.GraphicCrop)
    shape.Graphic = graphic
    after = (shape.Position.X, shape.Position.Y, shape.Size.Width, shape.Size.Height,
             shape.RotateAngle, shape.ZOrder, shape.GraphicCrop)
    if before != after:
        raise ValueError('Native photo replacement changed the original geometry or crop')
