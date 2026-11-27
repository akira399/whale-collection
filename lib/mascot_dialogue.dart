import 'dart:math';

import 'collection_models.dart';

enum MascotAction { feed, joke, surprise }

String chooseMascotLine(List<String> lines, String previous, Random random) {
  final choices = lines.where((line) => line != previous).toList();
  return choices[random.nextInt(choices.length)];
}

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
  '我数了三遍宝贝，每次都把自己算进去。',
  '你写提示词的时候，我偷偷补了一句：请多给鲸鱼放假。',
  '我的理想工作环境：一只宝箱、两颗泡泡、旁边还有你。',
];

const mascotFeeding = [
  '啊呜！这条小鱼好鲜。今日值班续航加满！',
  '谢谢投喂！我会把最后一口留到……已经吃完了。',
  '收到小鱼一条。回礼是把宝箱看得更紧一点！',
  '嚼嚼嚼。刚才说什么？我在认真品鉴。',
];

const mascotJokes = [
  '鲸鱼为什么很少迷路？因为随身带着一个海图（还涂了防水层）。',
  '为什么程序员喜欢来海底？因为这里到处都是泡泡（bubble），一看就是来排序的。',
  '什么鱼最擅长备份？记得存档的金鱼。等等，它记得吗？',
  '我问宝箱为什么不说话。它说，它只会开口。',
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
