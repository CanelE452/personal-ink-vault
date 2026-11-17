import 'package:flutter/material.dart';
import 'package:saber/data/user_error.dart';

/// One plain sentence, with the original error behind "자세히".
class UserErrorText extends StatefulWidget {
  const new({
    super.key,
    required this.message,
    this.details,
    this.style,
    this.textAlign,
  });

  /// [prefix] says what failed, for example "문서를 열 수 없습니다".
  factory of(
    Object error, {
    Key? key,
    String? prefix,
    String? extraDetails,
    TextStyle? style,
    TextAlign? textAlign,
  }) {
    final message = userErrorMessage(error);
    return UserErrorText(
      key: key,
      message: prefix == null ? message : '$prefix: $message',
      details: [
        userErrorDetails(error),
        ?extraDetails,
      ].join('\n'),
      style: style,
      textAlign: textAlign,
    );
  }

  final String message;
  final String? details;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  State<UserErrorText> createState() => _UserErrorTextState();
}

class _UserErrorTextState extends State<UserErrorText> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final details = widget.details?.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.textAlign == TextAlign.center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(widget.message, style: widget.style, textAlign: widget.textAlign),
        if (details != null && details.isNotEmpty) ...[
          TextButton(
            key: const ValueKey('user-error-details'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => setState(() => _open = !_open),
            child: Text(_open ? '자세히 닫기' : '자세히'),
          ),
          if (_open)
            SelectableText(
              details,
              style: const TextStyle(fontSize: 11),
              textAlign: widget.textAlign,
            ),
        ],
      ],
    );
  }
}

/// Shows [error] as one sentence in a snackbar that still closes on its own;
/// "자세히" opens the original error.
void showUserErrorSnackBar(BuildContext context, Object error) {
  logUserError(error);
  final details = userErrorDetails(error);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(userErrorMessage(error)),
      persist: false,
      action: SnackBarAction(
        label: '자세히',
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('오류 내용'),
            content: SingleChildScrollView(child: SelectableText(details)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('닫기'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
