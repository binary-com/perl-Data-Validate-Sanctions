use strict;
use Class::Unload;
use Data::Validate::Sanctions;
use YAML::XS qw(Dump);
use Path::Tiny qw(tempfile);
use Test::Warnings;
use Test::More;

my $validator = Data::Validate::Sanctions->new;

ok $validator->is_sanctioned('NEVEROV', 'Sergei Ivanovich', -253411200), "Sergei Ivanov is_sanctioned for sure";
my $result = $validator->get_sanctioned_info('abu', 'usama', -306028800);
is_deeply $result,
    {
    'comment'      => undef,
    'list'         => 'EU-Sanctions',
    'matched'      => 1,
    'matched_args' => {
        'dob_epoch' => -306028800,
        'name'      => 'Abu Usama'
    }
    },
    'Validation details are correct';

ok !$validator->is_sanctioned(qw(chris down)), "Chris is a good guy";

$result = $validator->get_sanctioned_info('ABBATTAY', 'Mohamed', 174614567);
is $result->{matched}, 0, 'ABBATTAY Mohamed is safe';

$result = $validator->get_sanctioned_info('Abu', 'Salem');
is $result->{matched}, 0, 'He used to match previously; but he has date of birth now.';
$result = $validator->get_sanctioned_info('Ali', 'Abu');
is $result->{matched}, 1, 'Should batch because has dob_text';

$result = $validator->get_sanctioned_info('Abu', 'Salem', '1948-10-10');
is_deeply $result,
    {
    'comment'      => undef,
    'list'         => 'OFAC-Consolidated',
    'matched'      => 1,
    'matched_args' => {
        'dob_year' => 1948,
        'name'     => 'Ibrahim ABU SALEM'
    }
    },
    'Validation details are correct';

my $tmpa = tempfile;

$tmpa->spew(
    Dump({
            test1 => {
                updated    => time,
                names_list => {
                    'TMPA' => {
                        'dob_epoch' => [],
                        'dob_year'  => []
                    },
                    'MOHAMMAD EWAZ Mohammad Wali' => {
                        'dob_epoch' => [],
                        'dob_year'  => []
                    },
                    'Zaki Izzat Zaki AHMAD' => {
                        'dob_epoch' => [],
                        'dob_year'  => [1999],
                        'dob_text'  => ['other info'],
                    },
                    'Atom' => {
                        'dob_year' => [1999],
                    },
                    'Donald Trump' => {
                        dob_text => ['circa-1951'],
                    },
                    'Optional Args' => {
                        place_of_birth => ['ir'],
                        residence      => ['fr', 'us'],
                        nationality    => ['de', 'gb'],
                        citizen        => ['ru'],
                        postal_code    => ['123321'],
                        national_id    => ['321123'],
                        passport_no    => ['asdffdsa'],
                    }
                },
            },
        }));

my $tmpb = tempfile;

$tmpb->spew(
    Dump({
            test2 => {
                updated    => time,
                names_list => {
                    'TMPB' => {
                        'dob_epoch' => [],
                        'dob_year'  => []}}
            },
        }));

$validator = Data::Validate::Sanctions->new(sanction_file => "$tmpa");
ok !$validator->is_sanctioned(qw(sergei ivanov)), "Sergei Ivanov not is_sanctioned";
ok $validator->is_sanctioned(qw(tmpa)), "now sanction file is tmpa, and tmpa is in test1 list";
ok !$validator->is_sanctioned("Mohammad reere yuyuy", "wqwqw  qqqqq"), "is not in test1 list";
ok !$validator->is_sanctioned("Zaki", "Ahmad"),                        "is in test1 list - but with a dob year";
ok $validator->is_sanctioned("Zaki", "Ahmad", '1999-01-05'), 'the guy is sanctioned when dob year is matching';
ok $validator->is_sanctioned("atom", "test", '1999-01-05'),  "Match correctly with one world name in sanction list";

is_deeply $validator->get_sanctioned_info("Zaki", "Ahmad", '1999-01-05'),
    {
    'comment'      => undef,
    'list'         => 'test1',
    'matched'      => 1,
    'matched_args' => {
        'dob_year' => 1999,
        'name'     => 'Zaki Izzat Zaki AHMAD'
    }
    },
    'Sanction info is correct';
ok $validator->is_sanctioned("Ahmad", "Ahmad", '1999-10-10'), "is in test1 list";

is_deeply $validator->get_sanctioned_info("TMPA"),
    {
    'comment'      => undef,
    'list'         => 'test1',
    'matched'      => 1,
    'matched_args' => {'name' => 'TMPA'}
    },
    'Sanction info is correct';

is_deeply $validator->get_sanctioned_info('Donald', 'Trump', '1999-01-05'),
    {
    'comment'      => 'dob raw text: circa-1951',
    'list'         => 'test1',
    'matched'      => 1,
    'matched_args' => {'name' => 'Donald Trump'}
    },
    "When client's name matches a case with dob_text";

is_deeply $validator->get_sanctioned_info('Optional', 'Args', '1999-01-05'),
    {
    'comment'      => undef,
    'list'         => 'test1',
    'matched'      => 1,
    'matched_args' => {'name' => 'Optional Args'}
    },
    "If optional ares are empty, only name is matched";

my $args = {
    place_of_birth => 'Iran',
    residence      => 'France',
    nationality    => 'Germany',
    citizen        => 'Russia',
    postal_code    => '123321',
    national_id    => '321123',
    passport_no    => 'asdffdsa',
};

is_deeply $validator->get_sanctioned_info('Optional', 'Args', '1999-01-05', $args),
    {
    'comment'      => undef,
    'list'         => 'test1',
    'matched'      => 1,
    'matched_args' => {
        name           => 'Optional Args',
        place_of_birth => 'ir',
        residence      => 'fr',
        nationality    => 'de',
        citizen        => 'ru',
        postal_code    => '123321',
        national_id    => '321123',
        passport_no    => 'asdffdsa',
    }
    },
    "All matched fields are returned";

for my $field (qw/place_of_birth residence nationality citizen postal_code national_id passport_no/) {
    is_deeply $validator->get_sanctioned_info('Optional', 'Args', '1999-01-05', {%$args, $field => 'Israel'}),
        {'matched' => 0}, "A single wrong field will result in mismatch - $field";

    my $expected_result = {
        'comment'      => undef,
        'list'         => 'test1',
        'matched'      => 1,
        'matched_args' => {
            name           => 'Optional Args',
            place_of_birth => 'ir',
            residence      => 'fr',
            nationality    => 'de',
            citizen        => 'ru',
            postal_code    => '123321',
            national_id    => '321123',
            passport_no    => 'asdffdsa',
        }};
    delete $expected_result->{matched_args}->{$field};
    is_deeply $validator->get_sanctioned_info('Optional', 'Args', '1999-01-05', {%$args, $field => undef}),
        $expected_result,
        "Missing optional args are ignored - $field";
}

Class::Unload->unload('Data::Validate::Sanctions');
local $ENV{SANCTION_FILE} = "$tmpb";
require Data::Validate::Sanctions;
$validator = Data::Validate::Sanctions->new;
ok $validator->is_sanctioned(qw(tmpb)), "get sanction file from ENV";
$validator = Data::Validate::Sanctions->new(sanction_file => "$tmpa");
ok $validator->is_sanctioned(qw(tmpa)), "get sanction file from args";

done_testing;
