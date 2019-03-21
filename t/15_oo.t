use strict;
use Class::Unload;
use Data::Validate::Sanctions;
use YAML::XS qw(Dump);
use Path::Tiny qw(tempfile);
use Test::More;

my $validator = Data::Validate::Sanctions->new;

ok $validator->is_sanctioned('NEVEROV', 'Sergei Ivanovich', -253411200), "Sergei Ivanov is_sanctioned for sure";
my $result = $validator->get_sanctioned_info('abu', 'usama', -306028800);
is $result->{matched}, 1,                 "Abu Usama is matched from get_sanctioned_info ";
is $result->{list},    'HMT-Sanctions',   "Abu Usama has correct list from get_sanctioned_info";
is $result->{name},    'ABU USAMA',       "Abu Usama has correct matched name from get_sanctioned_info";
is $result->{reason},  'Date of birth matches', "Reason is due to matching date of birth";
ok !$validator->is_sanctioned(qw(chris down)), "Chris is a good guy";

$result = $validator->get_sanctioned_info('ABBATTAY', 'Mohamed', 174614567);
is $result->{matched}, 0, 'ABBATTAY Mohamed is safe';

$result = $validator->get_sanctioned_info('Abu', 'Salem');
is $result->{matched}, 1, 'Abu Salem  is matched';
is $result->{list}, 'OFAC-SDN', 'Matched from correct sanction list with no date of birth provided';
is $result->{reason}, 'Name is similar', 'Correct reasoning found';

my $tmpa = tempfile;

$tmpa->spew(
    Dump({
            test1 => {
                updated => time,
                names_list   => {
                    'TMPA' => {
                        'dob_epoch' => []
                    },
                    'MOHAMMAD EWAZ Mohammad Wali' => {
                        'dob_epoch' => []
                    },
                    'Zaki Izzat Zaki AHMAD' => {
                        'dob_epoch' => []
                    }
                }
            }
        }));

my $tmpb = tempfile;

$tmpb->spew(
    Dump({
            test2 => {
                updated => time,
                names_list   => {
                    'TMPB' => {
                        'dob_epoch' => []
                    }
                }
            }
        }));

$validator = Data::Validate::Sanctions->new(sanction_file => "$tmpa");
ok !$validator->is_sanctioned(qw(sergei ivanov)), "Sergei Ivanov not is_sanctioned";
ok $validator->is_sanctioned(qw(tmpa)), "now sanction file is tmpa, and tmpa is in test1 list";
ok !$validator->is_sanctioned("Mohammad reere yuyuy", "wqwqw  qqqqq"), "is not in test1 list";
ok $validator->is_sanctioned("Zaki", "Ahmad"), "is in test1 list";
ok $validator->is_sanctioned("Ahmad", "Ahmad"), "is in test1 list";


Class::Unload->unload('Data::Validate::Sanctions');
local $ENV{SANCTION_FILE} = "$tmpb";
require Data::Validate::Sanctions;
$validator = Data::Validate::Sanctions->new;
ok $validator->is_sanctioned(qw(tmpb)), "get sanction file from ENV";
$validator = Data::Validate::Sanctions->new(sanction_file => "$tmpa");
ok $validator->is_sanctioned(qw(tmpa)), "get sanction file from args";
done_testing;
