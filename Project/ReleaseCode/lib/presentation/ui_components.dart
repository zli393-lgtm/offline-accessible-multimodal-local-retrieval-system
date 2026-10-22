import 'package:flutter/material.dart';

import '../configuration/presentation/pages/empty_message_values.dart';
import '../configuration/presentation/pages/metric_tile_values.dart';
import '../configuration/presentation/pages/page_heading_values.dart';
import '../configuration/presentation/pages/section_panel_values.dart';

class PageHeading extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const PageHeading({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: PageHeadingValues.iconBoxSize,
          height: PageHeadingValues.iconBoxSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(PageHeadingValues.iconRadius),
          ),
          child: Icon(
            icon,
            size: PageHeadingValues.iconSize,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(width: PageHeadingValues.iconToTextGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: PageHeadingValues.titleFontSize,
                  fontWeight:
                      FontWeight.values[PageHeadingValues.titleFontWeightIndex],
                ),
              ),
              const SizedBox(height: PageHeadingValues.titleToDescriptionGap),
              Text(
                description,
                style: TextStyle(
                  fontSize: PageHeadingValues.descriptionFontSize,
                  fontWeight: FontWeight
                      .values[PageHeadingValues.descriptionFontWeightIndex],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class SectionPanel extends StatelessWidget {
  final String title;
  final String? description;
  final Widget child;

  const SectionPanel({
    super.key,
    required this.title,
    this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.all(SectionPanelValues.outerMargin),
    elevation: SectionPanelValues.elevation,
    shape: RoundedRectangleBorder(
      side: BorderSide(
        color: Theme.of(context).colorScheme.outlineVariant,
        width: SectionPanelValues.borderWidth,
      ),
      borderRadius: BorderRadius.circular(SectionPanelValues.radius),
    ),
    child: Padding(
      padding: const EdgeInsets.all(SectionPanelValues.contentPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: TextStyle(
                fontSize: SectionPanelValues.titleFontSize,
                fontWeight:
                    FontWeight.values[SectionPanelValues.titleFontWeightIndex],
              ),
            ),
          ),
          if (description != null) ...[
            const SizedBox(height: SectionPanelValues.titleToDescriptionGap),
            Text(
              description!,
              style: TextStyle(
                fontSize: SectionPanelValues.descriptionFontSize,
                fontWeight: FontWeight
                    .values[SectionPanelValues.descriptionFontWeightIndex],
              ),
            ),
          ],
          const SizedBox(height: SectionPanelValues.headingToContentGap),
          child,
        ],
      ),
    ),
  );
}

class EmptyMessage extends StatelessWidget {
  final IconData icon;
  final String message;

  const EmptyMessage({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: message,
    excludeSemantics: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: EmptyMessageValues.horizontalPadding,
        vertical: EmptyMessageValues.verticalPadding,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(EmptyMessageValues.radius),
      ),
      child: Row(
        children: [
          Icon(icon, size: EmptyMessageValues.iconSize),
          const SizedBox(width: EmptyMessageValues.iconToMessageGap),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: EmptyMessageValues.messageFontSize,
                fontWeight: FontWeight
                    .values[EmptyMessageValues.messageFontWeightIndex],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label：$value',
    excludeSemantics: true,
    child: Container(
      constraints: const BoxConstraints(
        minWidth: MetricTileValues.minimumWidth,
        minHeight: MetricTileValues.minimumHeight,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: MetricTileValues.horizontalPadding,
        vertical: MetricTileValues.verticalPadding,
      ),
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(MetricTileValues.radius),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: MetricTileValues.valueFontSize,
              fontWeight:
                  FontWeight.values[MetricTileValues.valueFontWeightIndex],
            ),
          ),
          const SizedBox(height: MetricTileValues.valueToLabelGap),
          Text(
            label,
            style: TextStyle(
              fontSize: MetricTileValues.labelFontSize,
              fontWeight:
                  FontWeight.values[MetricTileValues.labelFontWeightIndex],
            ),
          ),
        ],
      ),
    ),
  );
}
