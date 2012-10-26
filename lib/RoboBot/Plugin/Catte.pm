package RoboBot::Plugin::Catte;

use strict;
use warnings;

sub commands { qw( catte dogge pony bike bear vidya food ) }
sub usage { '[[<id>] | [#<tag>] | [add|save <url>] | [delete|remove|forget <id>] | [tag <id> <tag>]]' }

sub handle_message {
    my ($class, $bot, $sender, $channel, $command, $original, $timestamp, $message) = @_;

    if ($message =~ m{^\s*(?:add|save)\s+(\w+.*)$}oi) {
        return save_catte($bot, $command, $sender, $1);
    } elsif ($message =~ m{^\s*(?:del(?:ete)?|rem(?:ove)?|rm|forget)\s+(\d+)\s*$}oi) {
        return delete_catte($bot, $command, $1);
    } elsif ($message =~ m{^tag\s+(\d+)\s+(\#?\w+)\s*}oi) {
        return tag_catte($bot, $command, $1, $2);
    } elsif ($message =~ m{^\s*\#(\w+)\s*$}oi) {
        return display_cattes($bot, $command, catte_by_tag($bot, $command, $1));
    } elsif ($message =~ m{^\s*(\d+)\s*$}o) {
        return display_cattes($bot, $command, $1);
    } elsif ($message =~ m{^\s*$}o) {
        return display_cattes($bot, $command, random_catte($bot, $command));
    }

    return;
}

sub display_cattes {
    my ($bot, $type, @ids) = @_;

    return 'Nothing found matching that criteria.' unless scalar(@ids) > 0;

    my $res = $bot->{'dbh'}->do(q{
        select cc.id, cc.catte_url
        from catte_cattes cc
            join catte_types ct on (ct.id = cc.type_id)
        where cc.id in ??? and ct.name = ? and not cc.deleted
    }, \@ids, $type);

    return unless $res;

    my @cattes = ();

    while ($res->next) {
        my $tags = $bot->{'dbh'}->do(q{
            select ct.tag_name
            from catte_catte_tags cct
                join catte_tags ct on (ct.id = cct.tag_id)
            where cct.catte_id = ?
            order by ct.tag_name asc
        }, $res->{'id'});

        my @t;

        if ($tags) {
            while ($tags->next) {
                push(@t, '#' . $tags->{'tag_name'});
            }
        }

        $res->{'catte_url'} .= ' [ ' . join(' ', @t) . ' ]'
            if @t && scalar(@t) > 0;

        push(@cattes, sprintf('[%d] %s', $res->{'id'}, $res->{'catte_url'}));
    }

    return 'Nothing found matching that criteria.' unless scalar(@cattes) > 0;
    return @cattes;
}

sub save_catte {
    my ($bot, $type, $sender, $message) = @_;

    $message =~ s{(^\s+|\s+$)}{}ogs;

    my $nick_id = sender_nick_id($bot, $sender);
    my $type_id = catte_type_id($bot, $type);

    my $res = $bot->{'dbh'}->do(q{
        insert into catte_cattes ??? returning id
    }, {    type_id     => $type_id,
            catte_url   => $message,
            added_by    => $nick_id,
    });

    return sprintf('An error occurred while attempting to save the %s.', $type) unless $res && $res->next;
    return sprintf('%s%s %d saved.', uc(substr($type, 0, 1)), substr($type, 1), $res->{'id'});
}

sub delete_catte {
    my ($bot, $type, $catte_id) = @_;

    my $res = $bot->{'dbh'}->do(q{
        update catte_cattes
        set deleted = true
        where id = ? and type_id = (select id from catte_types where name = ?)
    }, $catte_id, $type);

    return sprintf('An error occurred while deleting %s %d', $type, $catte_id) unless $res;
    return sprintf('%s%s %d has been deleted.', uc(substr($type, 0, 1)), substr($type, 1), $catte_id);
}

sub tag_catte {
    my ($bot, $type, $catte_id, $tag_name) = @_;

    $tag_name = normalize_tag($tag_name);
    return unless length($tag_name) > 0;

    my $tag_id;

    my $res = $bot->{'dbh'}->do(q{ select id from catte_tags where tag_name = ? }, $tag_name);

    if ($res && $res->next) {
        $tag_id = $res->{'id'};
    } else {
        $res = $bot->{'dbh'}->do(q{ insert into catte_tags (tag_name) values (?) returning id }, $tag_name);

        return unless $res && $res->next;
        $tag_id = $res->{'id'};
    }

    $res = $bot->{'dbh'}->do(q{ select * from catte_catte_tags where catte_id = ? and tag_id = ? }, $catte_id, $tag_id);

    return unless $res;
    return sprintf('%s%s %d already tagged with #%s',
        uc(substr($type, 0, 1)), substr($type, 1), $catte_id, $tag_name) if $res->next;

    $res = $bot->{'dbh'}->do(q{ insert into catte_catte_tags (catte_id, tag_id) values (?,?) }, $catte_id, $tag_id);

    return sprintf('An error occurred while tagging %s %d with #%s', $type, $catte_id, $tag_name) unless $res;
    return sprintf('%s%s %d has now been tagged with #%s',
        uc(substr($type, 0, 1)), substr($type, 1), $catte_id, $tag_name);
}

sub catte_by_tag {
    my ($bot, $type, $tag_name) = @_;

    $tag_name = normalize_tag($tag_name);

    my $res = $bot->{'dbh'}->do(q{
        select cc.id
        from catte_cattes cc
            join catte_catte_tags cct on (cct.catte_id = cc.id)
            join catte_tags ct on (ct.id = cct.tag_id)
            join catte_types cty on (cty.id = cc.type_id)
        where cty.name = ? and ct.tag_name = ? and not cc.deleted
        order by random()
        limit 1
    }, $type, $tag_name);

    return unless $res && $res->next;
    return $res->{'id'};
}

sub random_catte {
    my ($bot, $type) = @_;

    my $res = $bot->{'dbh'}->do(q{
        select cc.id
        from catte_cattes cc
            join catte_types ct on (ct.id = cc.type_id)
        where ct.name = ? and not cc.deleted
        order by random()
        limit 1
    }, $type);

    return unless $res && $res->next;
    return $res->{'id'};
}

sub normalize_tag {
    my ($tag) = @_;

    $tag =~ s{(^\s+|\s+$)}{}ogs;
    $tag =~ s{^\#}{}o;

    $tag = lc($tag) unless $tag =~ m{^https?}oi;

    return $tag;
}

sub sender_nick_id {
    my ($bot, $sender) = @_;

    $sender =~ s{\_+$}{}og;

    return $bot->{'db'}->{'nicks'}->{$sender}
        if $bot->{'db'}->{'nicks'} && $bot->{'db'}->{'nicks'}->{$sender};

    my $res = $bot->{'dbh'}->do(q{ select id from nicks where nick = ? }, $sender);

    $bot->{'db'}->{'nicks'} = {} unless $bot->{'db'}->{'nicks'};

    if ($res && $res->next) {
        $bot->{'db'}->{'nicks'}->{$sender} = $res->{'id'};

        return $res->{'id'};
    } else {
        $res = $bot->{'dbh'}->do(q{ insert into nicks (nick) values (?) returning id }, $sender);

        return unless $res && $res->next;

        $bot->{'db'}->{'nicks'}->{$sender} = $res->{'id'};

        return $res->{'id'};
    }
}

sub catte_type_id {
    my ($bot, $type) = @_;

    my $res = $bot->{'dbh'}->do(q{ select id from catte_types where name = ? }, $type);

    return $res->{'id'} if $res && $res->next;

    $res = $bot->{'dbh'}->do(q{ insert into catte_types (name) values (?) returning id }, $type);

    return unless $res && $res->next;
    return $res->{'id'};
}

1;
