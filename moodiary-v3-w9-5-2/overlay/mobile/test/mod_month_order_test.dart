import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/home/mod_month_order.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';

ModStoredBlock block(String id,{int event=100,int created=100,int edited=100})=>
  ModStoredBlock(blockId:id,revisionId:'revision-$id',parentRevisionId:null,
    topicId:'topic-unit-test',monthKey:'2026-11',kind:'entry',dayKey:'2026-11-07',
    occurredAtMs:event,createdAtMs:created,editedAtMs:edited,
    tiptapJson:'{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph"}]}',deleted:false);

void main(){
  test('event then original creation then ID; editing never changes stable ties',(){
    final blocks=[block('a-late',created:200,edited:1),
      block('z-first',created:100,edited:999999),
      block('a-same-creation',created:100,edited:2),
      block('event-before',event:50,created:900)];
    blocks.sort(modCompareBlocks);
    expect(blocks.map((b)=>b.blockId),
      ['event-before','a-same-creation','z-first','a-late']);
  });
  test('selected past day wins over today, preserving the current clock precision',(){
    final now=DateTime(2026,11,8,9,10,11,123,456);
    final selected=modInitialBlockTime(monthKey:'2026-11',dayKey:'2026-11-07',now:now);
    expect(selected,DateTime(2026,11,7,9,10,11,123,456));
    expect(modInitialBlockTime(monthKey:'2026-11',now:now),now);
    expect(modInitialBlockTime(monthKey:'2026-10',now:now),DateTime(2026,10,1,9,10,11,123,456));
  });
  test('invalid dates and mismatched month never normalize into a different day',(){
    for(final day in ['2026-11-31','0000-01-01','2026-2-01','not-a-day']){
      expect(modValidArchiveDay(day),false);
      expect(()=>modInitialBlockTime(monthKey:'2026-11',dayKey:day,now:DateTime(2026,11,8)),throwsArgumentError);
    }
    expect(modValidArchiveDay('2028-02-29'),true);
    expect(()=>modInitialBlockTime(monthKey:'2026-11',dayKey:'2026-12-01',now:DateTime(2026,11,8)),throwsArgumentError);
  });
}
