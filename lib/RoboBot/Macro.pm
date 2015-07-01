package RoboBot::Macro;

use v5.20;

use namespace::autoclean;

use Moose;
use MooseX::SetOnce;

use RoboBot::Nick;

use Clone qw( clone );
use Data::Dumper;
use Data::SExpression;
use DateTime;
use DateTime::Format::Pg;

has 'config' => (
    is       => 'ro',
    isa      => 'RoboBot::Config',
    required => 1,
);

has 'id' => (
    is        => 'rw',
    isa       => 'Num',
    traits    => [qw( SetOnce )],
    predicate => 'has_id',
);

has 'name' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

has 'arguments' => (
    is       => 'rw',
    isa      => 'ArrayRef',
    default  => sub { [] },
    required => 1,
);

has 'definition' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

has 'definer' => (
    is        => 'rw',
    isa       => 'RoboBot::Nick',
    predicate => 'has_definer',
);

has 'timestamp' => (
    is       => 'rw',
    isa      => 'DateTime',
    traits   => [qw( SetOnce )],
    default  => sub { DateTime->now() },
    required => 1,
);

has 'valid' => (
    is     => 'ro',
    isa    => 'Bool',
    writer => '_set_valid',
);

has 'error' => (
    is     => 'ro',
    isa    => 'Str',
    writer => '_set_error',
);

has 'expression' => (
    is     => 'ro',
    isa    => 'ArrayRef',
    writer => '_set_expression',
);

sub BUILD {
    my ($self) = @_;

    $self->_generate_expression($self->definition) if defined $self->definition;
}

around 'definition' => sub {
    my $orig = shift;
    my $self = shift;

    return $self->$orig() unless @_;

    my $def = shift;

    $self->_generate_expression($def);
    return $self->$orig($def);
};

sub _generate_expression {
    my ($self, $def) = @_;

    unless (defined $def) {
        $self->_set_expression([]);
        return;
    }

    my $ds = Data::SExpression->new({
        fold_lists       => 1,
        use_symbol_class => 1,
    });

    my $expr;

    eval {
        $expr = $ds->read($def);
    };

    if ($@) {
        $self->_set_valid(0);
        $self->_set_error("Macro definition is not a valid expression.");
        return;
    }

    unless (ref($expr) eq 'ARRAY') {
        $self->_set_valid(0);
        $self->_set_error("Macro definition body must be provided as a list of expressions.");
        return;
    }

    $self->_set_valid(1);
    $self->_set_expression($expr);
};

sub load_all {
    my ($class, $config) = @_;

    my $res = $config->db->do(q{
        select m.macro_id, m.name, m.arguments, m.definition, n.name as nick, m.defined_at
        from macros m
            join nicks n on (n.id = m.defined_by)
    });

    return unless $res;

    my %macros;

    while ($res->next) {
        $macros{$res->{'name'}} = $class->new(
            config     => $config,
            id         => $res->{'macro_id'},
            name       => $res->{'name'},
            arguments  => $res->{'arguments'},
            definition => $res->{'definition'},
            definer    => RoboBot::Nick->new( config => $config, name => $res->{'nick'} ),
            timestamp  => DateTime::Format::Pg->parse_datetime($res->{'defined_at'}),
        );
    }

    return %macros;
}

sub save {
    my ($self) = @_;

    my $res;

    if ($self->has_id) {
        $res = $self->config->db->do(q{
            update macros set ??? where macro_id = ?
        }, {
            name       => $self->name,
            arguments  => $self->arguments,
            definition => $self->definition,
        }, $self->id);

        return 1 if $res;
    } else {
        unless ($self->has_definer) {
            warn sprintf("Attempted to save macro '%s' without a definer attribute.\n", $self->name);
            return 0;
        }

        $res = $self->config->db->do(q{
            insert into macros ??? returning macro_id
        }, {
            name       => $self->name,
            arguments  => $self->arguments,
            definition => $self->definition,
            defined_by => $self->definer->id,
            defined_at => $self->timestamp,
        });

        if ($res && $res->next) {
            $self->id($res->{'macro_id'});
            return 1;
        }
    }

    return 0;
}

sub delete {
    my ($self) = @_;

    return 0 unless $self->has_id;

    my $res = $self->config->db->do(q{
        delete from macros where macro_id = ?
    }, $self->id);

    return 0 unless $res;
    return 1;
}

sub expand {
    my ($self, $message, @args) = @_;

    my $expr = clone($self->expression);

    if (@args != @{$self->arguments}) {
        $message->response->raise('Mismatched arguments. Macro %s expects %d, you provided %d.', $self->signature, scalar(@{$self->arguments}), scalar(@args));
        return 0;
    }

    my %rpl = ();
    $rpl{$_} = [$message->process_list(shift(@args))] for @{$self->arguments};

    $self->expand_list($expr, \%rpl);

    return $expr;
}

sub expand_list {
    my ($self, $list, $args) = @_;

    return unless ref($list) eq 'ARRAY';

    foreach my $el (@{$list}) {
        if (ref($el) eq 'ARRAY') {
            $self->expand_list($el, $args);
        } elsif (exists $args->{"$el"}) {
            $el = $args->{"$el"};
        }
    }
}

sub collapse {
    my ($class, $definition) = @_;

    unless (ref($definition) eq 'ARRAY') {
        return __PACKAGE__->quoted_string($definition);
    }

    my @r;
    push(@r, __PACKAGE__->collapse($_)) foreach @{$definition};

    return sprintf('(%s)', join(' ', @r));
}

sub quoted_string {
    my ($class, $string) = @_;

    return $string unless $string =~ m{\s+}o;

    $string =~ s{\"}{\\"}og;
    return sprintf('"%s"', $string);
}

sub signature {
    my ($self) = @_;

    return sprintf('(%s)', $self->name) if @{$self->arguments} < 1;
    return sprintf('(%s %s)', $self->name, join(' ', @{$self->arguments}));
}

__PACKAGE__->meta->make_immutable;

1;
