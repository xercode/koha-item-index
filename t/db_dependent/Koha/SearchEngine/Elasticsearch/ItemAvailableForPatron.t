#!/usr/bin/perl
#
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

use Modern::Perl;

use Test::More tests => 7;
use Test::NoWarnings;
use Test::MockModule;

use File::Basename qw( dirname );

use t::lib::Mocks;

BEGIN {
    # Mock pluginsdir and load Koha::Plugins *before* anything else can pull it
    # in (e.g. TestBuilder/Koha::Database), so the test plugins dir lands in @INC.
    my $path = dirname(__FILE__) . '/../../../../lib/plugins';
    t::lib::Mocks::mock_config( 'pluginsdir', $path );

    use_ok('Koha::Plugins');
    use_ok('Koha::Plugin::TestItemAvailableForPatron');
}

use t::lib::TestBuilder;
use Koha::Database;
use Koha::SearchEngine::Elasticsearch;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# Avoid reaching the (absent) message broker: item stores during sample-data
# setup would otherwise enqueue a reindex over STOMP and trip Test::NoWarnings.
my $indexer_module = Test::MockModule->new('Koha::SearchEngine::Elasticsearch::Indexer');
$indexer_module->mock( 'index_records', sub { } );

subtest 'item_available_for_patron hook drives the field (real plugin, three states)' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );

    # Use the real test plugin, but mock plugin discovery so we don't depend on
    # the install/enable DB state and no unrelated hooks fire while building items.
    my $plugin = Koha::Plugin::TestItemAvailableForPatron->new;
    my $module = Test::MockModule->new('Koha::Plugins');
    $module->mock( 'get_enabled_plugins', sub { return ($plugin); } );

    my $es = Koha::SearchEngine::Elasticsearch->new( { index => 'biblios' } );

    my $yes_item     = $builder->build_sample_item( { itemcallnumber => 'PATRON-YES' } );
    my $no_item      = $builder->build_sample_item( { itemcallnumber => 'PATRON-NO' } );
    my $abstain_item = $builder->build_sample_item( { itemcallnumber => 'WHATEVER' } );

    # A plugin "true" lifts the default conditions: a hold-blocked item becomes
    # available. (This is the key difference from the veto-only hidden hook.)
    is(
        $es->_item_available_for_patron( $yes_item, 0, 1 ), 1,
        'plugin true makes a default-unavailable item available'
    );

    # A plugin "false" overrides an otherwise-available item.
    is(
        $es->_item_available_for_patron( $no_item, 0, 0 ), 0,
        'plugin false makes a default-available item unavailable'
    );

    # Abstention (undef) falls back to the default conditions.
    is(
        $es->_item_available_for_patron( $abstain_item, 0, 0 ), 1,
        'abstention falls back to default conditions (plain item is available)'
    );
    is(
        $es->_item_available_for_patron( $abstain_item, 0, 1 ), 0,
        'abstention falls back to default conditions (a blocking hold makes it unavailable)'
    );

    $schema->storage->txn_rollback;
};

subtest 'no plugin opinion when plugins are disabled' => sub {
    plan tests => 1;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'enable_plugins', 0 );

    my $es      = Koha::SearchEngine::Elasticsearch->new( { index => 'biblios' } );
    my $no_item = $builder->build_sample_item( { itemcallnumber => 'PATRON-NO' } );

    # The hook is skipped entirely (short-circuits before any plugin); default
    # conditions apply, so a plain item is available despite the "PATRON-NO" plugin.
    is(
        $es->_item_available_for_patron( $no_item, 0, 0 ), 1,
        'plugin not consulted when enable_plugins is off; default conditions apply'
    );

    $schema->storage->txn_rollback;
};

subtest 'three-state priority: false > true, short-circuits at the first false' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );

    my $es     = Koha::SearchEngine::Elasticsearch->new( { index => 'biblios' } );
    my $module = Test::MockModule->new('Koha::Plugins');

    # [true, false] -> false wins (not available).
    my $t = Koha::Test::FakeAvailPlugin->new(1);
    my $f = Koha::Test::FakeAvailPlugin->new(0);
    $module->mock( 'get_enabled_plugins', sub { return ( $t, $f ); } );
    is( $es->_item_available_for_patron( undef, 0, 0 ), 0, 'a false wins over a prior true' );

    # [false, true] -> the first false short-circuits; the later plugin is NOT called.
    my $f2 = Koha::Test::FakeAvailPlugin->new(0);
    my $t2 = Koha::Test::FakeAvailPlugin->new(1);
    $module->mock( 'get_enabled_plugins', sub { return ( $f2, $t2 ); } );
    is( $es->_item_available_for_patron( undef, 0, 0 ), 0, 'a first false makes it unavailable' );
    is( $f2->{called},                                  1, 'the false plugin was called' );
    is( $t2->{called}, 0, 'a later plugin is NOT called after a false (short-circuit)' );

    # [true, true] -> available.
    my $t3 = Koha::Test::FakeAvailPlugin->new(1);
    my $t4 = Koha::Test::FakeAvailPlugin->new(1);
    $module->mock( 'get_enabled_plugins', sub { return ( $t3, $t4 ); } );
    is( $es->_item_available_for_patron( undef, 0, 0 ), 1, 'a true with no false makes it available' );

    # All abstaining -> default conditions (here a blocking hold -> unavailable),
    # confirming abstention never forces availability on its own.
    my $a1   = Koha::Test::FakeAvailPlugin->new(undef);
    my $a2   = Koha::Test::FakeAvailPlugin->new(undef);
    my $item = $builder->build_sample_item;
    $module->mock( 'get_enabled_plugins', sub { return ( $a1, $a2 ); } );
    is( $es->_item_available_for_patron( $item, 0, 1 ), 0, 'all abstaining -> default conditions apply' );

    $schema->storage->txn_rollback;
};

subtest 'the hook receives intransit and blocked_by_hold' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );

    my $es     = Koha::SearchEngine::Elasticsearch->new( { index => 'biblios' } );
    my $item   = $builder->build_sample_item;
    my $module = Test::MockModule->new('Koha::Plugins');

    # A plugin that records what it was handed, and abstains so the default
    # conditions still decide the outcome.
    my $spy = Koha::Test::SpyAvailPlugin->new;
    $module->mock( 'get_enabled_plugins', sub { return ($spy); } );

    $es->_item_available_for_patron( $item, 1, 0 );
    is( $spy->{params}->{intransit},       1, 'intransit is passed through to the plugin' );
    is( $spy->{params}->{blocked_by_hold}, 0, 'blocked_by_hold is passed through to the plugin' );

    $es->_item_available_for_patron( $item, 0, 1 );
    is( $spy->{params}->{intransit},       0, 'intransit reflects the current call' );
    is( $spy->{params}->{blocked_by_hold}, 1, 'blocked_by_hold reflects the current call' );

    $schema->storage->txn_rollback;
};

{

    package Koha::Test::FakeAvailPlugin;

    sub new {
        my ( $class, $value ) = @_;
        return bless { value => $value, called => 0 }, $class;
    }

    sub item_available_for_patron {
        my ( $self, $params ) = @_;
        $self->{called}++;
        return $self->{value};
    }

    sub get_metadata { return { name => 'Koha::Test::FakeAvailPlugin' }; }
}

{

    package Koha::Test::SpyAvailPlugin;

    sub new { return bless { params => undef }, shift; }

    sub item_available_for_patron {
        my ( $self, $params ) = @_;
        $self->{params} = $params;
        return undef;    # abstain
    }

    sub get_metadata { return { name => 'Koha::Test::SpyAvailPlugin' }; }
}
