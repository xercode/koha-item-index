#!/usr/bin/perl

# Copyright 2026 Xercode
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

# Bug XXXXX: reactive reindexing hooks. Transit, hold and library
# geolocation changes that do not touch the items table must still reindex the
# affected biblio(s), so the nested item documents keep the derived
# intransit/onhold/onrequest/geolocation fields fresh.

use Modern::Perl;

use Test::NoWarnings;
use Test::More tests => 8;
use Test::MockModule;

use Koha::Database;
use Koha::Hold;
use Koha::Holds;
use Koha::BackgroundJobs;
use Koha::BackgroundJob::UpdateBiblioItemsGeolocation;
use Koha::DateUtils qw( dt_from_string );

use t::lib::TestBuilder;
use t::lib::Mocks;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# Capture every reindex request so we can assert which biblios get reindexed
# without touching a live Elasticsearch.
my @index_calls;
my $indexer_module = Test::MockModule->new('Koha::SearchEngine::Elasticsearch::Indexer');
$indexer_module->mock(
    'index_records',
    sub {
        my ( $self, $record_numbers ) = @_;
        push @index_calls, ref $record_numbers eq 'ARRAY' ? @$record_numbers : $record_numbers;
    }
);

sub reset_calls { @index_calls = (); return; }

subtest 'Koha::Hold reactive reindex (Bug XXXXX)' => sub {
    plan tests => 11;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Elasticsearch' );

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $patron  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $biblio  = $builder->build_sample_biblio;
    my $item    = $builder->build_sample_item( { biblionumber => $biblio->biblionumber } );
    my $bibnum  = $biblio->biblionumber;

    my %hold_info = (
        borrowernumber  => $patron->borrowernumber,
        biblionumber    => $bibnum,
        itemnumber      => $item->itemnumber,
        branchcode      => $library->branchcode,
        reservedate     => dt_from_string->ymd,
        item_level_hold => 1,
        priority        => 1,
    );

    # Creation of an active item-level hold makes its item onrequest.
    reset_calls();
    my $hold = Koha::Hold->new( {%hold_info} )->store;
    is( scalar @index_calls, 1,       'creating an active item-level hold reindexes once' );
    is( $index_calls[0],     $bibnum, '...the hold biblio' );

    # A priority change does not affect onhold/onrequest.
    reset_calls();
    $hold->priority(5)->store;
    is( scalar @index_calls, 0, 'a priority change does not reindex' );

    # found NULL -> 'W' flips onhold true.
    reset_calls();
    $hold->set( { found => 'W' } )->store;
    is( scalar @index_calls, 1, q{found NULL -> 'W' reindexes (onhold flips true)} );

    # found 'W' -> 'T': both count as onhold/onrequest, so no change.
    reset_calls();
    $hold->set( { found => 'T' } )->store;
    is( scalar @index_calls, 0, q{found 'W' -> 'T' does not reindex (status unchanged)} );

    # Suspending an active hold drops onhold/onrequest.
    reset_calls();
    $hold->set( { suspend => 1 } )->store;
    is( scalar @index_calls, 1, 'suspending an active hold reindexes (onrequest flips false)' );

    # Cancelling an active hold reindexes (cancel() stores cancellationdate).
    my $hold_to_cancel = Koha::Hold->new( { %hold_info, found => 'W' } )->store;
    reset_calls();
    $hold_to_cancel->cancel;
    is( scalar @index_calls, 1,       'cancelling an active item-level hold reindexes' );
    is( $index_calls[0],     $bibnum, '...the hold biblio' );

    # Filling an item-level hold reindexes (fill() bypasses store()).
    my $hold_to_fill = Koha::Hold->new( { %hold_info, found => 'W' } )->store;
    reset_calls();
    $hold_to_fill->fill;
    is( scalar @index_calls, 1, 'filling an item-level hold reindexes' );

    # A record-level hold (no itemnumber) does not affect any item document.
    reset_calls();
    Koha::Hold->new( { %hold_info, itemnumber => undef, item_level_hold => 0 } )->store;
    is( scalar @index_calls, 0, 'creating a record-level hold does not reindex' );

    # No reindex when the search engine is not Elasticsearch.
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Zebra' );
    reset_calls();
    Koha::Hold->new( {%hold_info} )->store;
    is( scalar @index_calls, 0, 'no reindex when SearchEngine is not Elasticsearch' );

    $schema->storage->txn_rollback;
};

subtest 'Koha::Hold->delete reindex (Bug XXXXX)' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Elasticsearch' );

    my $library  = $builder->build_object( { class => 'Koha::Libraries' } );
    my $patron   = $builder->build_object( { class => 'Koha::Patrons' } );
    my $biblio_1 = $builder->build_sample_biblio;
    my $biblio_2 = $builder->build_sample_biblio;
    my $item_1   = $builder->build_sample_item( { biblionumber => $biblio_1->biblionumber } );
    my $item_2   = $builder->build_sample_item( { biblionumber => $biblio_2->biblionumber } );

    my %hold_info = (
        borrowernumber  => $patron->borrowernumber,
        biblionumber    => $biblio_1->biblionumber,
        itemnumber      => $item_1->itemnumber,
        branchcode      => $library->branchcode,
        reservedate     => dt_from_string->ymd,
        item_level_hold => 1,
        priority        => 1,
    );

    # Deleting an active item-level hold (e.g. Koha::Patron->lock with
    # remove) changes the onrequest status of its item.
    my $hold = Koha::Hold->new( {%hold_info} )->store;
    reset_calls();
    $hold->delete;
    is_deeply( \@index_calls, [ $biblio_1->biblionumber ], 'deleting an active item-level hold reindexes its biblio' );

    # A record-level hold does not affect any item document.
    $hold = Koha::Hold->new( { %hold_info, itemnumber => undef, item_level_hold => 0 } )->store;
    reset_calls();
    $hold->delete;
    is( scalar @index_calls, 0, 'deleting a record-level hold does not reindex' );

    $schema->storage->txn_rollback;
};

subtest 'Koha::Hold->move_hold reindex (Bug XXXXX)' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Elasticsearch' );

    my $library  = $builder->build_object( { class => 'Koha::Libraries' } );
    my $patron   = $builder->build_object( { class => 'Koha::Patrons' } );
    my $biblio_1 = $builder->build_sample_biblio;
    my $biblio_2 = $builder->build_sample_biblio;
    my $item_1   = $builder->build_sample_item( { biblionumber => $biblio_1->biblionumber } );
    my $item_2   = $builder->build_sample_item( { biblionumber => $biblio_2->biblionumber } );

    my %hold_info = (
        borrowernumber  => $patron->borrowernumber,
        biblionumber    => $biblio_1->biblionumber,
        itemnumber      => $item_1->itemnumber,
        branchcode      => $library->branchcode,
        reservedate     => dt_from_string->ymd,
        item_level_hold => 1,
        priority        => 1,
    );

    # Moving an item-level hold to an item of another record: both records
    # change (the original item is no longer onrequest, the new one is).
    my $reserves_module = Test::MockModule->new('C4::Reserves');
    $reserves_module->mock( 'CanItemBeReserved', sub { return { status => 'OK' } } );
    my $hold_module = Test::MockModule->new('Koha::Hold');
    $hold_module->mock( '_pickup_valid_for_item', sub { return 1 } );

    my $hold = Koha::Hold->new( {%hold_info} )->store;
    reset_calls();
    my $result = $hold->move_hold( { new_itemnumber => $item_2->itemnumber } );
    ok( $result->{success}, 'the hold is moved' );
    is_deeply(
        [ sort { $a <=> $b } @index_calls ],
        [ sort { $a <=> $b } ( $biblio_1->biblionumber, $biblio_2->biblionumber ) ],
        'moving an item-level hold to another record reindexes both records'
    );

    # Moving a record-level hold does not affect the original items.
    $hold = Koha::Hold->new( { %hold_info, itemnumber => undef, item_level_hold => 0 } )->store;
    reset_calls();
    $result = $hold->move_hold( { new_itemnumber => $item_2->itemnumber } );
    ok( $result->{success}, 'the record-level hold is moved' );
    ok(
        !( grep { $_ == $biblio_1->biblionumber } @index_calls ),
        'moving a record-level hold does not reindex the original record'
    );

    $schema->storage->txn_rollback;
};

subtest 'Koha::Hold found-P transition reindexes for available_for_patron (Bug XXXXX)' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Elasticsearch' );

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $patron  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $biblio  = $builder->build_sample_biblio;
    my $item    = $builder->build_sample_item( { biblionumber => $biblio->biblionumber } );
    my $bibnum  = $biblio->biblionumber;

    my $hold = Koha::Hold->new(
        {
            borrowernumber  => $patron->borrowernumber,
            biblionumber    => $bibnum,
            itemnumber      => $item->itemnumber,
            branchcode      => $library->branchcode,
            reservedate     => dt_from_string->ymd,
            item_level_hold => 1,
            priority        => 1,
        }
    )->store;

    # A pending (found NULL) item-level hold has onrequest=1, onhold=0,
    # blocked_by_hold=0. Moving it to 'P' (processing) leaves onhold/onrequest
    # untouched but flips blocked_by_hold true: it must still reindex so
    # available_for_patron is refreshed. This is the §4.1 gap that the
    # onhold/onrequest signature alone would miss.
    reset_calls();
    $hold->set( { found => 'P' } )->store;
    is( scalar @index_calls, 1,       q{found NULL -> 'P' reindexes (blocked_by_hold flips true)} );
    is( $index_calls[0],     $bibnum, '...the hold biblio' );

    # 'P' -> NULL flips blocked_by_hold back to false while onhold/onrequest stay
    # put, so it reindexes purely on the new component.
    reset_calls();
    $hold->set( { found => undef } )->store;
    is( scalar @index_calls, 1, q{found 'P' -> NULL reindexes (blocked_by_hold flips false)} );

    $schema->storage->txn_rollback;
};

subtest 'Koha::Item::Transfer reactive reindex (Bug XXXXX)' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Elasticsearch' );

    my $library_to = $builder->build_object( { class => 'Koha::Libraries' } );
    my $biblio     = $builder->build_sample_biblio;
    my $bibnum     = $biblio->biblionumber;

    # Cancelling an in-transit transfer flips intransit to false.
    my $item1     = $builder->build_sample_item( { biblionumber => $bibnum } );
    my $transfer1 = $item1->request_transfer( { to => $library_to, reason => 'Manual', ignore_limits => 1 } );
    $transfer1->transit;
    reset_calls();
    $transfer1->cancel( { reason => 'Manual', force => 1 } );
    is( scalar @index_calls, 1,       'cancelling an in-transit transfer reindexes' );
    is( $index_calls[0],     $bibnum, '...the item biblio' );

    # Cancelling a queued (not yet sent) transfer leaves intransit untouched.
    my $item2     = $builder->build_sample_item( { biblionumber => $bibnum } );
    my $transfer2 = $item2->request_transfer( { to => $library_to, reason => 'Manual', ignore_limits => 1 } );
    reset_calls();
    $transfer2->cancel( { reason => 'Manual' } );
    is( scalar @index_calls, 0, 'cancelling a not-yet-sent transfer does not reindex' );

    # transit() is already covered through Koha::Item->store (ModDateLastSeen).
    my $item3     = $builder->build_sample_item( { biblionumber => $bibnum } );
    my $transfer3 = $item3->request_transfer( { to => $library_to, reason => 'Manual', ignore_limits => 1 } );
    reset_calls();
    $transfer3->transit;
    ok( ( scalar @index_calls ) >= 1, 'transit() reindexes via Koha::Item->store (already covered)' );

    $schema->storage->txn_rollback;
};

subtest 'Koha::Library geolocation triggers a batch reindex (Bug XXXXX)' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Elasticsearch' );

    my @enqueued;
    my $job_module = Test::MockModule->new('Koha::BackgroundJob::UpdateBiblioItemsGeolocation');
    $job_module->mock(
        'enqueue',
        sub {
            my ( $self, $args ) = @_;
            push @enqueued, $args->{branchcode};
            return 1;
        }
    );

    my $library = $builder->build_object( { class => 'Koha::Libraries', value => { geolocation => '1.0,1.0' } } );

    # A real geolocation change enqueues a batch reindex for this library.
    @enqueued = ();
    $library->geolocation('2.0,2.0')->store;
    is( scalar @enqueued, 1,                    'changing geolocation enqueues a batch reindex' );
    is( $enqueued[0],     $library->branchcode, '...for this library' );

    # Editing any other field must not enqueue anything.
    @enqueued = ();
    $library->branchname('A brand new name')->store;
    is( scalar @enqueued, 0, 'changing a non-geolocation field does not enqueue' );

    # No enqueue when the search engine is not Elasticsearch.
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Zebra' );
    @enqueued = ();
    $library->geolocation('3.0,3.0')->store;
    is( scalar @enqueued, 0, 'no enqueue when SearchEngine is not Elasticsearch' );

    $schema->storage->txn_rollback;
};

subtest 'UpdateBiblioItemsGeolocation background job (Bug XXXXX)' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'SearchEngine', 'Elasticsearch' );

    # Avoid reaching the (absent) message broker when enqueuing for real.
    t::lib::Mocks::mock_preference( 'JobsNotificationMethod', 'polling' );

    my $library_a = $builder->build_object( { class => 'Koha::Libraries' } );
    my $library_b = $builder->build_object( { class => 'Koha::Libraries' } );

    # biblio_home: item whose home branch is the changed library.
    my $biblio_home = $builder->build_sample_biblio;
    $builder->build_sample_item( { biblionumber => $biblio_home->biblionumber, homebranch => $library_a->branchcode } );

    # biblio_holding: item whose holding branch is the changed library.
    my $biblio_holding = $builder->build_sample_biblio;
    $builder->build_sample_item(
        {
            biblionumber  => $biblio_holding->biblionumber,
            homebranch    => $library_b->branchcode,
            holdingbranch => $library_a->branchcode
        }
    );

    # biblio_other: item in an unrelated library.
    my $biblio_other = $builder->build_sample_biblio;
    $builder->build_sample_item(
        {
            biblionumber  => $biblio_other->biblionumber,
            homebranch    => $library_b->branchcode,
            holdingbranch => $library_b->branchcode
        }
    );

    my $job_id =
        Koha::BackgroundJob::UpdateBiblioItemsGeolocation->new->enqueue( { branchcode => $library_a->branchcode } );
    ok( $job_id, 'job enqueued' );

    my $job = Koha::BackgroundJobs->find($job_id)->_derived_class;
    is( $job->job_type, 'update_biblio_items_geolocation', 'correct job type' );

    reset_calls();
    $job->process( { branchcode => $library_a->branchcode } );

    my %reindexed = map { $_ => 1 } @index_calls;
    ok( $reindexed{ $biblio_home->biblionumber },    'biblio with a home item in the branch is reindexed' );
    ok( $reindexed{ $biblio_holding->biblionumber }, 'biblio with a holding item in the branch is reindexed' );
    ok( !$reindexed{ $biblio_other->biblionumber },  'unrelated biblio is not reindexed' );

    $job->discard_changes;
    is( $job->status, 'finished', 'job is marked finished' );

    $schema->storage->txn_rollback;
};
