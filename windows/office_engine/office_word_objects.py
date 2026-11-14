"""Native Frame binding and bounded PNG/JPEG preservation for Writer geometry.

Objects bind through their actual Frame content/range references. Inventory names,
collection order and graphic digests never establish object identity. Text-bearing
frames/custom drawings require a further verified preservation path.
"""
import office_presentation
from office_word_fidelity import properties, property_value, semantic_value


IMAGE_PROPERTIES = (
    'AnchorType', 'Width', 'Height', 'Size', 'RelativeWidth', 'RelativeHeight',
    'RelativeWidthRelation', 'RelativeHeightRelation', 'IsSyncWidthToHeight', 'IsSyncHeightToWidth',
    'HoriOrient', 'HoriOrientPosition', 'HoriOrientRelation',
    'VertOrient', 'VertOrientPosition', 'VertOrientRelation',
    'Surround', 'Opaque', 'IsFollowingTextFlow', 'SurroundAnchorOnly',
    'SurroundContour', 'ContourOutside', 'IsAutomaticContour', 'AllowOverlap',
    'LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin', 'FrameStyleName',
    'FillStyle', 'FillColor', 'LineStyle', 'LineColor', 'LineWidth', 'ZOrder',
    'GraphicCrop', 'GraphicFilter', 'GraphicRotation', 'BackColor', 'BackTransparent',
    'AdjustLuminance', 'AdjustContrast', 'AdjustRed', 'AdjustGreen', 'AdjustBlue', 'Gamma',
    'GraphicColorMode', 'Transparency', 'Visible', 'Print',
    'HoriMirroredOnEvenPages', 'HoriMirroredOnOddPages', 'VertMirrored', 'GraphicIsInverted',
    'LeftBorder', 'RightBorder', 'TopBorder', 'BottomBorder', 'BorderDistance',
    'LeftBorderDistance', 'RightBorderDistance', 'TopBorderDistance', 'BottomBorderDistance',
    'ContentProtected', 'PositionProtected', 'SizeProtected',
)


def image_properties(image):
    result = properties(image, IMAGE_PROPERTIES)
    for name in ('RelativeWidth', 'RelativeHeight'):
        if result[name] != ('integer', 0):
            raise ValueError('Relative Word image dimensions have no verified preservation path')
    for name in ('Width', 'Height'):
        value = result[name]
        if len(value) != 2 or value[0] != 'integer' or value[1] <= 0:
            raise ValueError('Word image dimensions cannot be verified')
    # BaseFrameProperties.idl defines positions only for orientation NONE (0).
    # Actual Writer source/live/reopen observations cover horizontal CENTER (2)
    # and vertical TOP (1); keep other modes explicitly unverified for this slice.
    for axis, computed in (('Hori', 2), ('Vert', 1)):
        mode = result[axis + 'Orient']
        position = result[axis + 'OrientPosition']
        relation = result[axis + 'OrientRelation']
        if mode not in (('integer', 0), ('integer', computed)):
            raise ValueError('Word image orientation has no verified preservation path')
        if position[0] != 'integer' or relation[0] != 'integer':
            raise ValueError('Word image placement cannot be verified')
        if mode == ('integer', computed):
            result[axis + 'OrientPosition'] = ('computed-by-orientation',)
    for name in ('SurroundContour', 'IsAutomaticContour'):
        if result[name] not in (('absent',), ('boolean', False)):
            raise ValueError('Word image contour wrapping has no verified preservation path')
    return result


class WordObjectRegistry:
    def __init__(self, document, context, uno, prop):
        self.context, self.uno, self.prop = context, uno, prop
        self.inventory, self.visited, self.export_bindings = [], [], []
        try:
            page = document.DrawPage
            count = page.Count
            if type(count) is not int or count < 0:
                raise ValueError('Word drawing inventory count cannot be verified')
            for index in range(count):
                self.add_inventory(page.getByIndex(index))
            for name in ('GraphicObjects', 'TextFrames', 'EmbeddedObjects'):
                collection = getattr(document, name)
                for key in collection.ElementNames:
                    self.add_inventory(collection.getByName(key))
        except Exception as error:
            raise ValueError('Word native object inventory cannot be verified') from error

    def add_inventory(self, value):
        if value is None:
            raise ValueError('Word native object inventory contains an unknown entry')
        if not any(value == previous for previous in self.inventory):
            self.inventory.append(value)

    def frame_content(self, portion, owner_text):
        try:
            enumeration = portion.createContentEnumeration('com.sun.star.text.TextContent')
            if not enumeration.hasMoreElements():
                raise ValueError('Word Frame has no native content reference')
            image = enumeration.nextElement()
            if enumeration.hasMoreElements():
                raise ValueError('Word Frame has multiple unverified native content references')
            if not any(image == previous for previous in self.inventory):
                raise ValueError('Word Frame content is absent from its native object inventory')
            if any(image == previous for previous in self.visited):
                raise ValueError('Word native object occurs in more than one Frame token')
            anchor = image.getAnchor()
            if anchor is None or owner_text is None or anchor.getText() != owner_text:
                raise ValueError('Word object anchor belongs to a different native text owner')
            owner_text.createTextCursorByRange(anchor)
            owner_text.createTextCursorByRange(portion.Start)
            if owner_text.compareRegionStarts(anchor.Start, portion.Start) != 0:
                raise ValueError('Word object anchor differs from its structural Frame position')
            if not image.supportsService('com.sun.star.text.TextGraphicObject'):
                raise ValueError('This Word object has no verified image preservation path')
            try:
                nested_text = image.Text
            except AttributeError:
                nested_text = None
            if nested_text is not None:
                raise ValueError('Text-bearing Word objects have no verified preservation path')
            formatting = image_properties(image)
            anchor_type = property_value(image, 'AnchorType')
            if getattr(anchor_type, 'value', None) not in ('AS_CHARACTER', 'AT_CHARACTER'):
                raise ValueError('Word image anchor type has no verified preservation path')
            graphic = property_value(image, 'Graphic')
            payload = {'mimeType': semantic_value('MimeType', graphic.MimeType),
                'sizePixel': semantic_value('Size', graphic.SizePixel),
                'sha256': office_presentation.graphic_digest(
                    self.context, graphic, self.uno, self.prop)}
            self.visited.append(image)
            token = {'kind': 'image', 'format': formatting, 'graphic': payload}
            self.export_bindings.append({'text': owner_text, 'portion': portion,
                'image': image, 'format': formatting, 'graphic': payload, 'token': token})
            return token
        except Exception as error:
            raise ValueError('Word Frame image preservation failed: ' + str(error)) from error

    def verify_complete(self):
        if len(self.visited) != len(self.inventory):
            raise ValueError('Word native object inventory contains an unvisited object')
