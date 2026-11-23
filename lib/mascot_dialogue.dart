import 'collection_models.dart';

String mascotGreeting(int hour) {
  final greeting = hour < 5
      ? '夜深啦'
      : hour < 12
      ? '早上好'
      : hour < 18
      ? '下午好'
      : '晚上好';
  return '$greeting！箱盖开好啦，今天捡到了什么宝贝？';
}

const mascotChatter = [
  '别看箱子小，里面可是我的工具宇宙！',
  '摸摸头可以，动我的宝箱得先预约！',
  '海底网速一般，好工具记得提前收藏。',
  '你负责发现宝藏，我负责在箱盖上监工。',
  '听说收藏夹越整齐，鲸鱼就越圆。证据？我就是！',
  '我刚打了个盹，箱子里不会又多了十个工具吧？',
  '下次说「那个很好用但忘了名字的工具」时，记得来问箱子。',
  '今日工作：看箱子、收宝贝，以及非常努力地发呆。',
];

String mascotQuip(CollectionCategory? category) => switch (category) {
  CollectionCategory.development => '代码工具箱又添一员，我负责鼓掌，报错你负责！',
  CollectionCategory.writing => '写字的活儿有帮手啦，我可以专心叼笔了。',
  CollectionCategory.design => '设计箱又亮了一格！我的箱盖什么时候能排上改版？',
  CollectionCategory.media => '音视频区来客啦！我的出场音效有着落了。',
  CollectionCategory.research => '查资料有人帮忙，我今天可以少潜两趟水。',
  CollectionCategory.productivity => '省下来的时间，申请划拨给鲸鱼午睡！',
  CollectionCategory.platforms => '模型区又热闹了，箱盖底下都快能开研讨会了！',
  CollectionCategory.other || null => '这件宝贝先留个位，有空再打开箱盖研究。',
};

String mascotReview(Entry entry) {
  final feature = entry.features.firstWhere(
    (feature) => feature.trim().isNotEmpty,
    orElse: () => '',
  );
  if (feature.isEmpty) return mascotQuip(entry.category);
  final text = compact(feature);
  final preview = clip(text, 32);
  final ending = preview == text ? '' : '…';
  return '${mascotQuip(entry.category)} 我先记下这项：「$preview$ending」。';
}
