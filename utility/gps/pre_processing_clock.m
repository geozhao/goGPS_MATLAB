function [pr1, ph1, pr2, ph2, dtR, dtRdot, bad_sats] = pre_processing_clock(time_ref, time, XR0, pr1, ph1, pr2, ph2, dop1, dop2, snr1, Eph, SP3, iono, lambda, nSatTot, waitbar_handle)

% SYNTAX:
%   [pr1, ph1, pr2, ph2, dtR, dtRdot, bad_sats] = pre_processing_clock(time_ref, time, XR0, pr1, ph1, pr2, ph2, dop1, dop2, snr1, Eph, SP3, iono, lambda, nSatTot, waitbar_handle);
%
% INPUT:
%   time_ref = GPS reference time
%   time     = GPS nominal time (as read from RINEX file)
%   XR0 = receiver position (=[] if not available)
%   pr1 = code observation (L1 carrier)
%   ph1 = phase observation (L1 carrier)
%   pr2 = code observation (L2 carrier)
%   ph2 = phase observation (L2 carrier)
%   dop1 = Doppler observation (L1 carrier)
%   dop2 = Doppler observation (L2 carrier)
%   snr1 = signal-to-noise ratio
%   Eph = matrix containing 33 ephemerides for each satellite
%   SP3 = structure with precise ephemeris and clock
%   iono = ionosphere parameters (Klobuchar)
%   lambda  = wavelength matrix (depending on the enabled constellations)
%   nSatTot = maximum number of satellites (given the enabled constellations)
%   waitbar_handle = handle to the waitbar object

% OUTPUT:
%   pr1 = processed code observation (L1 carrier)
%   ph1 = processed phase observation (L1 carrier)
%   pr2 = processed code observation (L2 carrier)
%   ph2 = processed phase observation (L2 carrier)
%   dtR = receiver clock error
%   dtRdot receiver clock drift
%   bad_sats = vector for flagging "bad" satellites (e.g. too few observations, code without phase, etc)
%
% DESCRIPTION:
%   Pre-processing of code and phase observations to correct them for
%    the receiver clock error.

%----------------------------------------------------------------------------------------------
%                           goGPS v0.4.2 beta
%
% Copyright (C) 2009-2014 Mirko Reguzzoni, Eugenio Realini
%----------------------------------------------------------------------------------------------
%
%    This program is free software: you can redistribute it and/or modify
%    it under the terms of the GNU General Public License as published by
%    the Free Software Foundation, either version 3 of the License, or
%    (at your option) any later version.
%
%    This program is distributed in the hope that it will be useful,
%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%    GNU General Public License for more details.
%
%    You should have received a copy of the GNU General Public License
%    along with this program.  If not, see <http://www.gnu.org/licenses/>.
%----------------------------------------------------------------------------------------------

global cutoff snr_threshold n_sys

v_light = goGNSS.V_LIGHT;

%number of epochs
nEpochs = length(time);

%receiver clock error
dtR = zeros(nEpochs,1);

%receiver clock drift
dtRdot = zeros(nEpochs-1,1);

%vector for flagging "bad" satellites (e.g. too few observations, code without phase, etc)
bad_sats = zeros(nSatTot,1);

%--------------------------------------------------------------------------------------------
% APPROXIMATE POSITION
%--------------------------------------------------------------------------------------------

if ((sum(abs(XR0)) == 0) || isempty(XR0))
    %approximate position not available
    flag_XR = 0;
else
    %approximate position available
    flag_XR = 1;
end

for i = 1 : nEpochs
    
    %--------------------------------------------------------------------------------------------
    % SATELLITE AND EPHEMERIS SELECTION
    %--------------------------------------------------------------------------------------------
    
    sat0 = find(pr1(:,i) ~= 0);

    Eph_t = rt_find_eph (Eph, time(i), nSatTot);
    
    %----------------------------------------------------------------------------------------------
    % RECEIVER POSITION AND CLOCK ERROR
    %----------------------------------------------------------------------------------------------
    
    min_nsat_LS = 3 + n_sys;
    
    if (length(sat0) >= min_nsat_LS)
        
        [~, dtR_tmp, ~, ~, ~, ~, ~, ~, ~, sat] = init_positioning(time(i), pr1(sat0,i), snr1(sat0,i), Eph_t, SP3, iono, [], XR0, [], [], sat0, [], lambda(sat0,:), cutoff, snr_threshold, 1, flag_XR, 0);
        
        if (~isempty(dtR_tmp))
            dtR(i) = dtR_tmp;
        end
        
        if (size(sat,1) >= min_nsat_LS)
            
            if (i > 1)
                %compute receiver clock drift
                if (dtR(i) ~= 0 && dtR(i-1) ~= 0)
                    dtRdot(i-1) = (dtR(i) - dtR(i-1))/(time(i) - time(i-1));
                end
            end
        else
            if (i > 2)
                dtR(i) = dtR(i-1) + (dtR(i-1) - dtR(i-2));
                dtRdot(i-1) = (dtR(i) - dtR(i-1))/(time(i) - time(i-1));
            end
        end
    else
        if (i > 2)
            dtR(i) = dtR(i-1) + (dtR(i-1) - dtR(i-2));
            dtRdot(i-1) = (dtR(i) - dtR(i-1))/(time(i) - time(i-1));
        end
    end
    
    if (nargin > 15 && ~isempty(waitbar_handle))
        waitbar_handle.goTime(i);
    end
end

%----------------------------------------------------------------------------------------------
% RECEIVER CLOCK DRIFT DISCONTINUITIES
%----------------------------------------------------------------------------------------------

%check if there is any discontinuity in the clock drift
clock_thresh = 1e-5;
disc = find(abs(dtRdot-mean(dtRdot)) > clock_thresh);

%remove discontinuities from the clock drift
for i = 1 : length(disc)
    if (disc(i) < 5)
        dtRdot(disc(i)) = median(dtRdot(1:10));
    elseif (disc(i) <= nEpochs-6)
        dtRdot(disc(i)) = median(dtRdot(disc(i)-4:disc(i)+5));
    elseif (disc(i) > nEpochs-6)
        dtRdot(disc(i)) = median(dtRdot(nEpochs-10:nEpochs-1));
    end
end

dtRdot(end+1) = dtRdot(end);

%check if it is needed to correct observations for receiver clocks offsets
% (some RINEX files contain clock-corrected observations, although they are
%  not respecting the specifications); clock offsets lower than 1
%  microsecond don't need to be corrected
if (max(abs(dtR)) < 1e-6)
    return
end

%check which observations must be corrected for receiver clock offsets
% (some receivers have inconsistent observations, e.g. code with clock
%  jumps, phase wihtout)

%jump detection threshold
j_thres = (clock_thresh*10)*v_light;

%flags
flag_jumps_pr1 = 0;
flag_jumps_pr2 = 0;
flag_jumps_ph1 = 0;
flag_jumps_ph2 = 0;

for i = 1 : length(disc)
    
    for s = 1 : nSatTot
        
        %check code on L1
        if (pr1(s,disc(i):disc(i)+1) ~= 0)
            if (abs(diff(pr1(s,disc(i):disc(i)+1))) > j_thres)
                flag_jumps_pr1 = 1;
            end
        end
        
        %check code on L2
        if (pr2(s,disc(i):disc(i)+1) ~= 0)
            if (abs(diff(pr2(s,disc(i):disc(i)+1))) > j_thres)
                flag_jumps_pr2 = 1;
            end
        end
        
        %check phase on L1
        if (ph1(s,disc(i):disc(i)+1) ~= 0)
            if (abs(diff(ph1(s,disc(i):disc(i)+1)))*lambda(s,1) > j_thres)
                flag_jumps_ph1 = 1;
            end
        end
        
        %check phase on L2
        if (ph2(s,disc(i):disc(i)+1) ~= 0)
            if (abs(diff(ph2(s,disc(i):disc(i)+1)))*lambda(s,2) > j_thres)
                flag_jumps_ph2 = 1;
            end
        end
        
        %no need to go through all satellites
        if (any([flag_jumps_pr1 flag_jumps_pr2 flag_jumps_ph1 flag_jumps_ph2]))
            break
        end
    end
    
    %no need to go through all discontinuities
    if (any([flag_jumps_pr1 flag_jumps_pr2 flag_jumps_ph1 flag_jumps_ph2]))
        break
    end
end

%----------------------------------------------------------------------------------------------
% OBSERVATION CORRECTION FOR CLOCK ERROR
%----------------------------------------------------------------------------------------------

%two types of corrections (as in http://www.navcen.uscg.gov/?pageName=RINEX):
% 1. "frequency correction" c*dtR
% 2. "receiver-satellite dynamics correction" by using Doppler if available,
%     otherwise by interpolating observations on the time tag corrected by dtR

%available epochs
index_e = find(time ~= 0);

%nominal time desynchronization (e.g. with some low-cost receivers)
time_desync = time_ref - time;

%reference time "correction"
time_ref(index_e) = time(index_e) + dtR(index_e) + time_desync(index_e);

for s = 1 : nSatTot

    if (any(pr1(s,:)))

        index_s = find(pr1(s,:) ~= 0);
        index = intersect(index_e,index_s);
        
        if (length(index) > 1)
            
            if (flag_jumps_pr1)
                pr1(s,index) = pr1(s,index) - v_light*dtR(index)';
            end
            % if (any(dop1(s,index)))
            %     pr1(s,index) = pr1(s,index) + (time_ref(index) - time(index))'.*(f1 - dop1(s,index))*lambda(s,1);
            % else
            pr1(s,index) = interp1(time(index), pr1(s,index), time_ref(index), 'spline');
            % end
        else
            bad_sats(s) = 1;
        end
    end
    
    if (any(pr2(s,:)))
        
        index_s = find(pr2(s,:) ~= 0);
        index = intersect(index_e,index_s);
        
        if (length(index) > 1)
            
            if (flag_jumps_pr2)
                pr2(s,index) = pr2(s,index) - v_light*dtR(index)';
            end
            % if (any(dop2(s,index)))
            %     pr2(s,index) = pr2(s,index) + (time_ref(index) - time(index))'.*(f2 - dop2(s,index))*lambda(s,2);
            % else
            pr2(s,index) = interp1(time(index), pr2(s,index), time_ref(index), 'spline');
            % end
        else
            bad_sats(s) = 1;
        end
    end
    
    if (any(ph1(s,:)))
        
        index_s = find(ph1(s,:) ~= 0);
        index = intersect(index_e,index_s);
        
        if (length(index) > 1)
            
            if (flag_jumps_ph1)
                ph1(s,index) = ph1(s,index) - v_light*dtR(index)'/lambda(s,1);
            end
            % if (any(dop1(s,index)))
            %     ph1(s,index) = ph1(s,index) + (time_ref(index) - time(index))'.*(f1 - dop1(s,index));
            % else
            ph1(s,index) = interp1(time(index), ph1(s,index), time_ref(index), 'spline');
            % end
        else
            bad_sats(s) = 1;
        end
        
    elseif (any(pr1(s,:)))
        
        bad_sats(s) = 1;
    end
    
    if (any(ph2(s,:)))
        
        index_s = find(ph2(s,:) ~= 0);
        index = intersect(index_e,index_s);
        
        if (length(index) > 1)
            
            if (flag_jumps_ph2)
                ph2(s,index) = ph2(s,index) - v_light*dtR(index)'/lambda(s,2);
            end
            % if (any(dop2(s,index)))
            %     ph2(s,index) = ph2(s,index) + (time_ref(index) - time(index))'.*(f2 - dop2(s,index));
            % else
            ph2(s,index) = interp1(time(index), ph2(s,index), time_ref(index), 'spline');
            % end
        else
            bad_sats(s) = 1;
        end
        
    elseif (any(pr2(s,:)))
        
        bad_sats(s) = 1;
    end
end