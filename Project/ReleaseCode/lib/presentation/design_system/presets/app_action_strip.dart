import 'package:flutter/material.dart';

import '../../../configuration/presentation/controls/action_strip_values.dart';

class AppActionStrip extends StatelessWidget {
  final List<Widget> children;

  const AppActionStrip({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    child: FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Align(
        alignment: Alignment.centerLeft,
        heightFactor: ActionStripValues.heightFactor,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: ActionStripValues.height,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var index = 0; index < children.length; index++) ...[
                  if (index > 0) const SizedBox(width: ActionStripValues.gap),
                  children[index],
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
