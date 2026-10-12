class ListingSearchFilters {
  final String type;
  final String category;
  final String city;
  final String query;
  final double? minPrice;
  final double? maxPrice;
  final String sort;
  final String condition;
  final Map<String, String> details;
  final double radius;

  const ListingSearchFilters({
    this.type = 'all',
    this.category = 'הכל',
    this.city = '',
    this.query = '',
    this.minPrice,
    this.maxPrice,
    this.sort = 'newest',
    this.condition = 'all',
    this.details = const {},
    this.radius = 0,
  });

  Map<String, String> get queryParameters => {
        'page': '1',
        if (type != 'all') 'type': type,
        if (category != 'הכל') 'category': category,
        if (city.trim().isNotEmpty) 'city': city.trim(),
        if (query.trim().isNotEmpty) 'q': query.trim(),
        if (minPrice != null) 'minPrice': minPrice.toString(),
        if (maxPrice != null) 'maxPrice': maxPrice.toString(),
        if (sort != 'newest') 'sort': sort,
        if (condition != 'all') 'condition': condition,
        if (category != 'הכל')
          for (final entry in details.entries)
            if (entry.value.trim().isNotEmpty)
              'detail_${entry.key}': entry.value.trim(),
        if (radius > 0) 'radius': radius.toStringAsFixed(0),
      };
}
